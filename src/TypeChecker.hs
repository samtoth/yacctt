module TypeChecker where

import Control.Applicative
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Gen
import qualified Data.Map as Map
import qualified Data.Traversable as T

import Cartesian
import CTT
import Eval

-- Type checking monad
type Typing a = ReaderT TEnv (ExceptT String (GenT Int IO)) a

-- Environment for type checker
data TEnv =
  TEnv { names   :: [String] -- generated names
       , indent  :: Int
       , env     :: Env
       , verbose :: Bool  -- Should it be verbose and print what it typechecks?
       } deriving (Eq)

verboseEnv, silentEnv :: TEnv
verboseEnv = TEnv [] 0 emptyEnv True
silentEnv  = TEnv [] 0 emptyEnv False

-- Trace function that depends on the verbosity flag
trace :: String -> Typing ()
trace s = do
  b <- asks verbose
  when b $ liftIO (putStrLn s)

-- Helper functions for eval
evalTC :: Env -> Ter -> Typing Val
evalTC rho t = lift $ lift $ eval rho t

appTC :: Val -> Val -> Typing Val
appTC u v = lift $ lift $ app u v

convTC :: Convertible a => [String] -> a -> a -> Typing Bool
convTC ns u v = lift $ lift $ conv ns u v

normalTC :: Normal a => [String] -> a -> Typing a
normalTC ns u = lift $ lift $ normal ns u

(@@@) :: ToII a => Val -> a -> Typing Val
v @@@ r = lift $ lift $ v @@ toII r

-------------------------------------------------------------------------------
-- | Functions for running computations in the type checker monad

runTyping :: TEnv -> Typing a -> IO (Either String a)
runTyping env t = runGenT $ runExceptT $ runReaderT t env

runDecls :: TEnv -> Decls -> IO (Either String TEnv)
runDecls tenv d = runTyping tenv $ do
  checkDecls d
  return $ addDecls d tenv

runDeclss :: TEnv -> [Decls] -> IO (Maybe String,TEnv)
runDeclss tenv []     = return (Nothing, tenv)
runDeclss tenv (d:ds) = do
  x <- runDecls tenv d
  case x of
    Right tenv' -> runDeclss tenv' ds
    Left s      -> return (Just s, tenv)

runInfer :: TEnv -> Ter -> IO (Either String Val)
runInfer lenv e = runTyping lenv (infer e)

-------------------------------------------------------------------------------
-- | Modifiers for the environment

addTypeVal :: (Ident,Val) -> TEnv -> TEnv
addTypeVal (x,a) (TEnv ns ind rho v) =
  let w@(VVar n _) = mkVarNice ns x a
  in TEnv (n:ns) ind (upd (x,w) rho) v

addSub :: (Name,II) -> TEnv -> TEnv
addSub iphi (TEnv ns ind rho v) = TEnv ns ind (sub iphi rho) v

addSubs :: [(Name,II)] -> TEnv -> TEnv
addSubs = flip $ foldr addSub

addType :: (Ident,Ter) -> TEnv -> Typing TEnv
addType (x,a) tenv@(TEnv _ _ rho _) = do
  va <- evalTC rho a
  return $ addTypeVal (x,va) tenv

addBranch :: [(Ident,Val)] -> Env -> TEnv -> TEnv
addBranch nvs env (TEnv ns ind rho v) =
  TEnv ([n | (_,VVar n _) <- nvs] ++ ns) ind (upds nvs rho) v

addDecls :: Decls -> TEnv -> TEnv
addDecls d (TEnv ns ind rho v) = TEnv ns ind (def d rho) v

addTele :: Tele -> TEnv -> Typing TEnv
addTele xas lenv = foldM (flip addType) lenv xas

-- Only works for equations in a system (so of shape (Name,II))
faceEnv :: Eqn -> TEnv -> Typing TEnv
faceEnv ir tenv = do
  tenv' <- lift $ lift $ env tenv `face` ir
  return $ tenv{env=tenv'}

-------------------------------------------------------------------------------
-- | Various useful functions

-- Extract the type of a label as a closure
getLblType :: LIdent -> Val -> Typing (Tele, Env)
getLblType c (Ter (Sum _ _ cas) r) = case lookupLabel c cas of
  Just as -> return (as,r)
  Nothing -> throwError ("getLblType: " ++ show c ++ " in " ++ show cas)
getLblType c (Ter (HSum _ _ cas) r) = case lookupLabel c cas of
  Just as -> return (as,r)
  Nothing -> throwError ("getLblType: " ++ show c ++ " in " ++ show cas)
getLblType c u = throwError ("expected a data type for the constructor "
                             ++ c ++ " but got " ++ show u)

-- Monadic version of unless
unlessM :: Monad m => m Bool -> m () -> m ()
unlessM mb x = mb >>= flip unless x

mkVars :: [String] -> Tele -> Env -> Typing [(Ident,Val)]
mkVars _ [] _ = return []
mkVars ns ((x,a):xas) nu = do
  va <- evalTC nu a
  let w@(VVar n _) = mkVarNice ns x va
  xs <- mkVars (n:ns) xas (upd (x,w) nu)
  return $ (x,w) : xs

-- Test if two values are convertible
(===) :: Convertible a => a -> a -> Typing Bool
u === v = do
  ns <- asks names
  convTC ns u v

-- eval in the typing monad
evalTyping :: Ter -> Typing Val
evalTyping t = do
  rho <- asks env
  evalTC rho t

-------------------------------------------------------------------------------
-- | The bidirectional type checker

-- Check that t has type a
check :: Val -> Ter -> Typing ()
check a t = case (a,t) of
  (_,Undef{}) -> return ()
  (_,Hole l)  -> do
      rho <- asks env
      let e = unlines (reverse (contextOfEnv rho))
      ns <- asks names
      na <- normalTC ns a
      trace $ "\nHole at " ++ show l ++ ":\n\n" ++
              e ++ replicate 80 '-' ++ "\n" ++ show na ++ "\n"
  (_,Con c es) -> do
    (bs,nu) <- getLblType c a
    checks (bs,nu) es
  (VU,Pi f)       -> checkFam f
  (VU,Sigma f)    -> checkFam f
  (VU,Sum _ _ bs) -> forM_ bs $ \lbl -> case lbl of
    OLabel _ tele -> checkTele tele
    PLabel _ tele is ts ->
      throwError $ "check: no path constructor allowed in " ++ show t
  (VU,HSum _ _ bs) -> forM_ bs $ \lbl -> case lbl of
    OLabel _ tele -> checkTele tele
    PLabel _ tele is ts -> do
      checkTele tele
      rho <- asks env
      unless (all (`elem` is) (eqnSupport ts)) $
        throwError "names in path label system" -- TODO
      mapM_ checkFresh is
      let iis = zip is (map Name is)
      local (addSubs iis) $ localM (addTele tele) $ do
        checkSystemWith ts $ \alpha talpha ->
          localM (faceEnv alpha) $
            -- NB: the type doesn't depend on is
            check (Ter t rho) talpha
        rho' <- asks env
        ts' <- lift $ lift $ evalSystem rho' ts
        checkCompSystem ts'
  (VPi va@(Ter (Sum _ _ cas) nu) f,Split _ _ ty ces) -> do
    check VU ty
    rho <- asks env
    ty' <- evalTC rho ty    
    unlessM (a === ty') $ throwError "check: split annotations"
    if map labelName cas == map branchName ces
       then sequence_ [ checkBranch (lbl,nu) f brc (Ter t rho) va
                      | (brc, lbl) <- zip ces cas ]
       else throwError "case branches does not match the data type"
  (VPi va@(Ter (HSum _ _ cas) nu) f,Split _ _ ty ces) -> do
    check VU ty
    rho <- asks env
    ty' <- evalTC rho ty
    unlessM (a === ty') $ throwError "check: split annotations"
    if map labelName cas == map branchName ces
       then sequence_ [ checkBranch (lbl,nu) f brc (Ter t rho) va
                      | (brc, lbl) <- zip ces cas ]
       else throwError "case branches does not match the data type"
  (VPi a f,Lam x a' t)  -> do
    check VU a'
    ns <- asks names
    rho <- asks env
    a'' <- evalTC rho a'
    na <- normalTC ns a
    unlessM (a === a'') $
      throwError $ "check: lam types don't match"
        ++ "\nlambda type annotation: " ++ show a'
        ++ "\ndomain of Pi: " ++ show a
        ++ "\nnormal form of type: " ++ show na
    let var = mkVarNice ns x a
    local (addTypeVal (x,a)) $ do
      f' <- appTC f var
      check f' t
  (VSigma a f, Pair t1 t2) -> do
    check a t1
    v <- evalTyping t1
    f' <- appTC f v
    check f' t2
  (_,Where e d) -> do
    local (\tenv@TEnv{indent=i} -> tenv{indent=i + 2}) $ checkDecls d
    local (addDecls d) $ check a e
  (VU,PathP a e0 e1) -> do
    (a0,a1) <- checkPLam (constPath VU) a
    check a0 e0
    check a1 e1
  (VPathP p a0 a1,PLam _ e) -> do
    (u0,u1) <- checkPLam p t
    ns <- asks names
    (nu0,nu1) <- normalTC ns (u0,u1)
    (na0,na1) <- normalTC ns (a0,a1)
    unlessM (convTC ns a0 u0) $
      throwError $ "Left endpoints don't match for \n" ++ show e ++ "\ngot\n" ++
                   show u0 ++ "\nbut expected\n" ++ show a0 ++
                   "\n\nNormal forms:\n" ++ show nu0 ++ "\nand\n" ++ show na0
    unlessM (convTC ns a1 u1) $
      throwError $ "Right endpoints don't match for \n" ++ show e ++ "\ngot\n" ++
                   show u1 ++ "\nbut expected\n" ++ show a1 ++
                   "\n\nNormal forms:\n" ++ show nu1 ++ "\nand\n" ++ show na1
  (VU,LineP a) -> do
    checkPLam (constPath VU) a
    return ()
  (VLineP a,PLam _ e) -> do
    checkPLam a t
    return ()
  (VU,V r a b e) -> do
    checkII r
    check VU b
    localM (faceEnv (eqn (r,0))) $ do
      check VU a
      va <- evalTyping a
      vb <- evalTyping b
      checkEquiv va vb e
  (VV i a b e,Vin s m n) -> do
    checkII s
    unless (Name i == s) $
      throwError $ "The names " ++ show i ++ " " ++ show s ++ " do not match in Vin"
    check b n
    localM (faceEnv (eqn (s,0))) $ do
      check a m
      vm <- evalTyping m
      vn <- evalTyping n
      ns <- asks names
      evm <- appTC (equivFun e) vm
      unlessM (convTC ns evm vn) $
        throwError $ "Vin does not match V type"
  -- (VU,Glue a ts) -> do
  --   check VU a
  --   rho <- asks env
  --   checkGlue (eval rho a) ts
  -- (VGlue va ts,GlueElem u us) -> do
  --   check va u
  --   vu <- evalTyping u
  --   checkGlueElem vu ts us
  -- (VCompU va ves,GlueElem u us) -> do
  --   check va u
  --   vu <- evalTyping u
  --   checkGlueElemU vu ves us
  _ -> do
    v <- infer t
    unlessM (v === a) $
      throwError $ "check conv:\n" ++ show v ++ "\n/=\n" ++ show a


-- Check a list of declarations
checkDecls :: Decls -> Typing ()
checkDecls (MutualDecls _ []) = return ()
checkDecls (MutualDecls l d)  = do
  a <- asks env
  let (idents,tele,ters) = (declIdents d,declTele d,declTers d)
  ind <- asks indent
  trace (replicate ind ' ' ++ "Checking: " ++ unwords idents)
  checkTele tele
  local (addDecls (MutualDecls l d)) $ do
    rho <- asks env
    checks (tele,rho) ters
checkDecls (OpaqueDecl _)      = return ()
checkDecls (TransparentDecl _) = return ()
checkDecls TransparentAllDecl  = return ()

localM :: (TEnv -> Typing TEnv) -> Typing a -> Typing a
localM f r = do
  e <- ask
  a <- f e
  local (const a) r

-- Check a telescope
checkTele :: Tele -> Typing ()
checkTele []          = return ()
checkTele ((x,a):xas) = do
  check VU a
  localM (addType (x,a)) $ checkTele xas

-- Check a family
checkFam :: Ter -> Typing ()
checkFam (Lam x a b) = do
  check VU a
  localM (addType (x,a)) $ check VU b
checkFam x = throwError $ "checkFam: " ++ show x

-- Check that a system is compatible
checkCompSystem :: System Val -> Typing ()
checkCompSystem vus = do
  ns <- asks names
  b <- lift $ lift $ isCompSystem ns vus
  unless b (throwError $ "Incompatible system " ++ show vus)

-- -- Check the values at corresponding faces with a function, assumes
-- -- systems have the same faces
-- checkSystemsWith :: (Show a, Show b) => System a -> System b -> (Eqn -> a -> b -> Typing c) -> Typing ()
-- checkSystemsWith (Sys us) (Sys vs) f = sequence_ $ Map.elems $ Map.intersectionWithKey f us vs
-- checkSystemsWith (Triv u) (Triv v) f = f (eqn (0,0)) u v >> return () -- TODO: Does it make sense to use the trivial equation here?
-- checkSystemsWith x y  _= throwError $ "checkSystemsWith: cannot compare " ++ show x ++ " and " ++ show y

-- Check the faces of a system
checkSystemWith :: System a -> (Eqn -> a -> Typing b) -> Typing ()
checkSystemWith (Sys us) f = sequence_ $ Map.elems $ Map.mapWithKey f us
checkSystemWith (Triv u) f = f (eqn (0,0)) u >> return () -- TODO: Does it make sense to use the trivial equation here?

-- Check a glueElem
-- checkGlueElem :: Val -> System Val -> System Ter -> Typing ()
-- checkGlueElem vu ts us = do
--   unless (keys ts == keys us)
--     (throwError ("Keys don't match in " ++ show ts ++ " and " ++ show us))
--   rho <- asks env
--   checkSystemsWith ts us
--     (\alpha vt u -> local (faceEnv alpha) $ check (equivDom vt) u)
--   let vus = evalSystem rho us
--   checkSystemsWith ts vus (\alpha vt vAlpha ->
--     unlessM (app (equivFun vt) vAlpha === (vu `subst` alpha)) $
--       throwError $ "Image of glue component " ++ show vAlpha ++
--                    " doesn't match " ++ show vu)
--   checkCompSystem vus

-- Check a glueElem against VComp _ ves
-- checkGlueElemU :: Val -> System Val -> System Ter -> Typing ()
-- checkGlueElemU vu ves us = do
--   unless (keys ves == keys us)
--     (throwError ("Keys don't match in " ++ show ves ++ " and " ++ show us))
--   rho <- asks env
--   checkSystemsWith ves us
--     (\alpha ve u -> local (faceEnv alpha) $ check (ve @@ One) u)
--   let vus = evalSystem rho us
--   checkSystemsWith ves vus (\alpha ve vAlpha ->
--     unlessM (eqFun ve vAlpha === (vu `subst` alpha)) $
--       throwError $ "Transport of glueElem (for compU) component " ++ show vAlpha ++
--                    " doesn't match " ++ show vu)
--   checkCompSystem vus

-- checkGlue :: Val -> System Ter -> Typing ()
-- checkGlue va ts = do
--   checkSystemWith ts (\alpha tAlpha -> checkEquiv (va `subst` alpha) tAlpha)
--   rho <- asks env
--   checkCompSystem (evalSystem rho ts)

-- An iso for a type b is a five-tuple: (a,f,g,s,t)   where
--  a : U
--  f : a -> b
--  g : b -> a
--  s : forall (y : b), f (g y) = y
--  t : forall (x : a), g (f x) = x
-- mkIso :: Val -> Val
-- mkIso vb = eval rho $
--   Sigma $ Lam "a" U $
--   Sigma $ Lam "f" (Pi (Lam "_" a b)) $
--   Sigma $ Lam "g" (Pi (Lam "_" b a)) $
--   Sigma $ Lam "s" (Pi (Lam "y" b $ PathP (PLam (N "_") b) (App f (App g y)) y)) $
--     Pi (Lam "x" a $ PathP (PLam (N "_") a) (App g (App f x)) x)
--   where [a,b,f,g,x,y] = map Var ["a","b","f","g","x","y"]
--         rho = upd ("b",vb) emptyEnv

-- An equivalence for a type a is a triple (t,f,p) where
-- t : U
-- f : t -> a
-- p : (x : a) -> isContr ((y:t) * Id a x (f y))
-- with isContr c = (z : c) * ((z' : C) -> Id c z z')
-- mkEquiv :: Val -> Val
-- mkEquiv va = eval rho $
--   Sigma $ Lam "t" U $
--   Sigma $ Lam "f" (Pi (Lam "_" t a)) $
--   Pi (Lam "x" a $ iscontrfib)
--   where [a,b,f,x,y,s,t,z] = map Var ["a","b","f","x","y","s","t","z"]
--         rho = upd ("a",va) emptyEnv
--         fib = Sigma $ Lam "y" t (PathP (PLam (N "_") a) x (App f y))
--         iscontrfib = Sigma $ Lam "s" fib $
--                      Pi $ Lam "z" fib $ PathP (PLam (N "_") fib) s z

-- RedPRL style equiv between A and B:
-- f : A -> B
-- p : (x : B) -> isContr ((y : A) * Path B (f y) x)
-- with isContr C = (s : C) * ((z : C) -> Path C z s)
mkEquiv :: Val -> Val -> Typing Val
mkEquiv va vb = evalTC rho $
  Sigma $ Lam "f" (Pi (Lam "_" a b)) $
  Pi (Lam "x" b iscontrfib)
  where [a,b,f,x,y,s,z] = map Var ["a","b","f","x","y","s","z"]
        rho = upd ("a",va) (upd ("b",vb) emptyEnv)
        fib = Sigma $ Lam "y" a (PathP (PLam (N "_") b) (App f y) x)
        iscontrfib = Sigma $ Lam "s" fib $
                     Pi $ Lam "z" fib $ PathP (PLam (N "_") fib) z s


-- Part 3 style equiv between A and B:
-- f : A -> B
-- p : (x : B) -> isContr ((y : A) * Path B (f y) x)
-- with isContr C = C * ((c c' : C) -> Path C c c')
-- mkEquiv :: Val -> Val -> Typing Val
-- mkEquiv va vb = evalTC rho $
--   Sigma $ Lam "f" (Pi (Lam "_" a b)) $
--   Pi (Lam "x" b iscontrfib)
--   where [a,b,f,x,y,s,z] = map Var ["a","b","f","x","y","s","z"]
--         rho = upd ("a",va) (upd ("b",vb) emptyEnv)
--         fib = Sigma $ Lam "y" a (PathP (PLam (N "_") b) (App f y) x)
--         iscontrfib = Sigma $ Lam "_" fib $
--                      Pi $ Lam "s" fib $ Pi $ Lam "z" fib $ PathP (PLam (N "_") fib) s z

checkEquiv :: Val -> Val -> Ter -> Typing ()
checkEquiv va vb equiv = do
  e <- mkEquiv va vb
  check e equiv

-- checkIso :: Val -> Ter -> Typing ()
-- checkIso vb iso = check (mkIso vb) iso

checkBranch :: (Label,Env) -> Val -> Branch -> Val -> Val -> Typing ()
checkBranch (OLabel _ tele,nu) f (OBranch c ns e) _ _ = do
  ns' <- asks names
  ns'' <- mkVars ns' tele nu
  let us = map snd ns''
  local (addBranch (zip ns us) nu) $ do
    f' <- appTC f (VCon c us)
    check f' e
checkBranch (PLabel _ tele is ts,nu) f (PBranch c ns js e) g va = do
  ns' <- asks names
  -- mapM_ checkFresh js
  us <- mkVars ns' tele nu
  let vus  = map snd us
      js'  = map Name js
  vts <- lift $ lift $ evalSystem (subs (zip is js') (upds us nu)) ts
  vgts <- lift $ lift $ runSystem $ intersectWith app (border g vts) vts
  local (addSubs (zip js js') . addBranch (zip ns vus) nu) $ do
    f' <- appTC f (VPCon c va vus js')
    check f' e
    ve  <- evalTyping e -- TODO: combine with next two lines?
    let veborder = border ve vts :: System Val
    unlessM (veborder === vgts) $
      throwError $ "Faces in branch for " ++ show c ++ " don't match:"
                   ++ "\ngot\n" ++ show veborder ++ "\nbut expected\n"
                   -- ++ show vgts

checkII :: II -> Typing ()
checkII phi = do
  rho <- asks env
  let dom = domainEnv rho
  unless (all (`elem` dom) (supportII phi)) $
    throwError $ "checkII: " ++ show phi

checkFresh :: Name -> Typing ()
checkFresh i = do
  rho <- asks env
  when (i `occurs` rho)
    (throwError $ show i ++ " is already declared")

-- Check that a term is a PLam and output the source and target
checkPLam :: Val -> Ter -> Typing (Val,Val)
checkPLam v (PLam i a) = do
  rho <- asks env
  -- checkFresh i
  local (addSub (i,Name i)) $ do
    vi <- v @@@ i
    check vi a
  (,) <$> evalTC (sub (i,Dir 0) rho) a <*> evalTC (sub (i,Dir 1) rho) a
checkPLam v t = do
  vt <- infer t
  case vt of
    VPathP a a0 a1 -> do
      unlessM (a === v) $ throwError (
        "checkPLam\n" ++ show v ++ "\n/=\n" ++ show a)
      return (a0,a1)
    VLineP a -> do
      unlessM (a === v) $ throwError (
        "checkPLam\n" ++ show v ++ "\n/=\n" ++ show a)
      -- vt0 <- vt @@@ Dir Zero
      -- vt1 <- vt @@@ Dir One
      return (VAppII vt 0,VAppII vt 1)
    _ -> throwError $ show vt ++ " is not a path"

checkPLamSystem :: II -> Ter -> Val -> System Ter -> Typing ()
checkPLamSystem r u0 va (Sys us) = do
  T.sequence $ Map.mapWithKey (\eqn u ->
    localM (faceEnv eqn) $ do
      rhoeqn <- asks env
      va' <- lift $ lift $ va `face` eqn
      checkPLam va' u
      vu <- evalTC rhoeqn u
      vur <- vu @@@ evalII rhoeqn r
      vu0 <- evalTC rhoeqn u0
      unlessM (vur === vu0) $
        throwError $ "\nThe face " ++ show eqn ++ " of the system\n" ++
                     show (Sys us) ++ "\nat " ++ show r ++ " is " ++ show vur ++
                     "\nwhich does not match the cap " ++ show vu0) us
  -- Check that the system ps is compatible.
  rho <- asks env
  us' <- lift $ lift $ evalSystem rho (Sys us)
  checkCompSystem us'
checkPLamSystem r u0 va (Triv u) = do
  rho <- asks env
  checkPLam va u
  vu <- evalTC rho u
  vur <- vu @@@ evalII rho r
  vu0 <- evalTC rho u0
  unlessM (vur === vu0) $
    throwError ("Trivial system " ++ show vur ++ " at " ++ show r ++
                "\ndoes not match the cap " ++ show vu0)

checks :: (Tele,Env) -> [Ter] -> Typing ()
checks ([],_)         []     = return ()
checks ((x,a):xas,nu) (e:es) = do
  va <- evalTC nu a
  check va e
  v' <- evalTyping e
  checks (xas,upd (x,v') nu) es
checks _ _ = throwError "checks: incorrect number of arguments"

-- infer the type of e
infer :: Ter -> Typing Val
infer e = case e of
  U           -> return VU  -- U : U
  Var n       -> do
    rho <- asks env
    lift $ lift $ lookType n rho
  App t u -> do
    c <- infer t
    case c of
      VPi a f -> do
        check a u
        v <- evalTyping u
        appTC f v
      _       -> throwError $ show c ++ " is not a product"
  Fst t -> do
    c <- infer t
    case c of
      VSigma a f -> return a
      _          -> throwError $ show c ++ " is not a sigma-type"
  Snd t -> do
    c <- infer t
    case c of
      VSigma a f -> do
        v <- evalTyping t
        appTC f (fstVal v)
      _          -> throwError $ show c ++ " is not a sigma-type"
  Where t d -> do
    checkDecls d
    local (addDecls d) $ infer t
  Vproj r o a b e -> do
    check VU (V r a b e)
    v <- evalTyping (V r a b e)
    check v o
    evalTyping b
  -- UnGlueElem e a ts -> do
  --   check VU (Glue a ts)
  --   vgl <- evalTyping (Glue a ts)
  --   check vgl e
  --   va <- evalTyping a
  --   return va
  AppII e r -> do
    checkII r
    t <- infer e
    case t of
      VPathP a _ _ -> a @@@ r
      VLineP a -> a @@@ r
      _ -> throwError (show e ++ " is not a path")
  HCom r s a us u0 -> do
    checkII r
    checkII s
    check VU a
    va <- evalTyping a
    check va u0
    -- check that it's a system
    checkPLamSystem r u0 (constPath va) us
    return va
  Com r s a us u0 -> do
    checkII r
    checkII s
    checkPLam (constPath VU) a
    va <- evalTyping a
    var <- va @@@ r
    check var u0
    checkPLamSystem r u0 va us
    va @@@ s
  Coe r s a u -> do
    checkII r
    checkII s
    checkPLam (constPath VU) a
    va <- evalTyping a
    var <- va @@@ r
    check var u
    va @@@ s
  PCon c a es phis -> do
    check VU a
    va <- evalTyping a
    (bs,nu) <- getLblType c va
    checks (bs,nu) es
    mapM_ checkII phis
    return va
  _ -> throwError ("infer " ++ show e)

-- Not used since we have U : U
--
-- (=?=) :: Typing Ter -> Ter -> Typing ()
-- m =?= s2 = do
--   s1 <- m
--   unless (s1 == s2) $ throwError (show s1 ++ " =/= " ++ show s2)
--
-- checkTs :: [(String,Ter)] -> Typing ()
-- checkTs [] = return ()
-- checkTs ((x,a):xas) = do
--   checkType a
--   local (addType (x,a)) (checkTs xas)
--
-- checkType :: Ter -> Typing ()
-- checkType t = case t of
--   U              -> return ()
--   Pi a (Lam x b) -> do
--     checkType a
--     local (addType (x,a)) (checkType b)
--   _ -> infer t =?= U
