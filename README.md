# yayacctt: Yet Another Yet Another Cartesian Cubical Type Theory

Experiments with a proof assistant implementing cartesian cubical type theory forked from [yacctt](https://github.com/mortberg/yacctt). 

 ### Goals
 * Changing the model of HITs to use the '3 HIT' model ((indexed) W types, Coequalisers and SpokeHub types). Just these 3 types can model a reasonable subset of all possible HITs. It is also simpler to implement hcom and coe than in the general case.
 * In place the of 'split' syntax, experiment with allowing only primitive induction/recursion - this might end up being too impractical - but is at least simpler to implement than a termination checker.
 * Implementing some form of graphical presentation of holes with a good treatment of cubical boundaries. This could work together with some form of interactive edditing ala 'agda mode'.  


 ## Original readme

This is an extremely experimental implementation of a cartesian
cubical type theory based on https://arxiv.org/abs/1712.01800 written by
Anders Mörtberg and Carlo Angiuli. It is mainly meant as proof of
concept and for experimentation with new cubical features and ideas.

It is based on the code base of https://github.com/mortberg/cubicaltt/.

