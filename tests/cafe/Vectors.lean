import Cafe

def main : IO Unit := do
  for t in ["hot", "iced"] do
    for s in ["small", "regular", "large"] do
      for m in ["whole", "skim", "oat", "almond", "soy"] do
        for h in ["single", "double", "triple"] do
          for d in [false, true] do
            IO.println (Cafe.preview t s m h d)
