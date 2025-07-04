module Utils

import Data.Singleton
import Data.Fin
import Data.String

%default total

public export
error : String -> a
error x = assert_total (idris_crash x)

-- | A literal
public export
data Lit = Str String | Chr Char | Num Nat

public export
Show Lit where
  show (Str s) = show s
  show (Chr c) = show c
  show (Num n) = show n

-- Singletons extra

public export
(.value) : {0 x : a} -> Singleton x -> a
(.value) (Val x) = x

public export
(.identity) : {0 x : a} -> (s : Singleton x) -> s.value = x
(.identity) (Val y) = Refl

public export
decToSemiDec : Dec a -> Maybe a
decToSemiDec (Yes x) = Just x
decToSemiDec (No _) = Nothing

public export
interface SemiDecEq a where
  semiDecEq : (x : a) -> (y : a) -> Maybe (x = y)

-- Text stuff

public export
indented : String -> String
indented s = (lines ("\n" ++ s) |> map (\l => "  " ++ l) |> joinBy "\n") ++ "\n"

-- Source location

public export
record Loc where
  constructor MkLoc
  src : List Char
  pos : Nat -- not necessarily in range

public export
dummyLoc : Loc
dummyLoc = MkLoc [] Z

public export
linesBefore : Loc -> List String
linesBefore loc = lines (substr 0 loc.pos (pack loc.src))

public export
(.row) : Loc -> Nat
(.row) loc = length (linesBefore loc)

public export
(.col) : Loc -> Nat
(.col) loc = case linesBefore loc of
  [] => 1
  (x::xs) => length (last (x::xs)) + 1

export
Show Loc where
  show m = "line " ++ show m.row ++ ", column " ++ show m.col
