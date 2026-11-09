"""Murdoku for KOReader: offline puzzle generator (our own code).

Modules:
  objects   object table (read from the plugin's murdoku_objects.lua)
  model     puzzle model and clue atoms
  solver    solution counter, logical solver with a reasoned trace, grader
  themes    themed rooms, furniture, names and case titles
  layout    floor plans, furniture and a random valid solution
  clues     true clue sentences (atoms + English) for a solution
  generate  the classic generation pipeline (--classic)
  steps     step solver naming each technique; aha profile and score
  aha       'designed aha' generation (default): accept filter + clue hill-climb
  stephints hints from the step solver's trace
  hints     step-by-step player hints from the solver trace
  export    site v2 JSON, plain-text playtest sheets
  textparse independent English -> atoms parser used by --check
"""
