module Main (main) where


import Distribution.Simple
import Distribution.Simple.Program
import System.Process (system)

main :: IO ()
main = defaultMainWithHooks $ simpleUserHooks {
  hookedPrograms = [bnfc],
  preBuild = \args buildFlags -> do
      _ <- system "bnfc --haskell -d Exp.cf -o src"
      preBuild simpleUserHooks args buildFlags
}

bnfc :: Program
bnfc = (simpleProgram "bnfc") {
    programFindVersion = findProgramVersion "--version" id
  }

