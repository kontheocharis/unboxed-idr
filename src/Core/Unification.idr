-- Unification for values in the core language
module Core.Unification

import Utils
import Common
import Decidable.Equality
import Data.Singleton
import Core.Base
import Core.Syntax
import Core.Evaluation
import Core.Metavariables

%default covering

-- Unification

-- Unification outcome
--
-- Observationally means under all substitutions from the empty context.
public export
data Unification : Ctx -> Type where
  -- Are observationally the same
  AreSame : Unification ns
  -- Are observationally different
  AreDifferent : Unification ns
  -- Can't really tell; could become the same (or different) under
  -- appropriate substitutions
  DontKnow : Unification ns
  -- An error occurred while solving a metavariable
  -- Also remembers all the extra binders we were solving under.
  Error : {under : Arity} -> SolveError (ns ::< under) -> Unification ns

-- Escape a unification result under a binder, by storing the binder name
-- in the result.
--
-- If the binder didn't have a name, we just use the name `_` which stands for
-- "internal binder".
escapeBinder : Maybe (Singleton n) -> Unification (ns :< n) -> Unification ns
escapeBinder sn AreSame = AreSame
escapeBinder sn AreDifferent = AreDifferent
escapeBinder sn DontKnow = DontKnow
escapeBinder (Just (Val n)) (Error {under = ar} err) = Error {under = n :: ar} err
escapeBinder Nothing (Error {under = ar} err) = Error {under = (Explicit, "_") :: ar} ?err

-- The typeclass for unification
--
-- The monad is indexed over if we are allowed to solve metavariables.
public export
interface (HasMetas m) => Unify m sm (0 lhs : Ctx -> Type) (0 rhs : Ctx -> Type) where
  -- Resolve any metas in terms, no-op by default
  resolveLhs : lhs ns -> m sm (lhs ns)
  resolveLhs x = pure x
  resolveRhs : rhs ns -> m sm (rhs ns)
  resolveRhs x = pure x

  -- Unify two terms, given the size of the context, assuming both sides are
  -- already resolved
  unifyImpl : Size ns -> lhs ns -> rhs ns -> m sm (Unification ns)

-- The actual unification function, first resolves both sides.
public export
unify : Unify m sm lhs rhs => Size ns -> lhs ns -> rhs ns -> m sm (Unification ns)
unify @{u} s l r = do
  l' <- resolveLhs @{u} l
  r' <- resolveRhs @{u} r
  unifyImpl s l' r'

-- Definitively decide a unification outcome based on a decidable equality
public export
ifAndOnlyIf : Monad m => Dec (a ~=~ b) -> ((a ~=~ b) -> m (Unification ns)) -> m (Unification ns)
ifAndOnlyIf (Yes Refl) f = f Refl
ifAndOnlyIf (No _) _ = pure AreDifferent

-- Definitively decide a unification outcome based on a semi-decidable equality
--
-- This is a "hack" because really we should be providing DecEq to be sure they
-- are different. However sometimes it is super annoying to implement DecEq so
-- we just use this instead.
public export
ifAndOnlyIfHack : Monad m => Maybe (a ~=~ b) -> ((a ~=~ b) -> m (Unification ns)) -> m (Unification ns)
ifAndOnlyIfHack (Just Refl) f = f Refl
ifAndOnlyIfHack Nothing _ = pure AreDifferent

-- Partially decide a unification outcome based on a semi-decidable equality
public export
inCase : Monad m => Maybe (a ~=~ b) -> ((a ~=~ b) -> m (Unification ns)) -> m (Unification ns)
inCase (Just Refl) f = f Refl
inCase Nothing _ = pure DontKnow

export infixr 5 /\
export infixr 4 \/

-- Conjunction of unification outcomes (fully monadic version)
public export
(/\) : (Monad m) => m (Unification ns) -> m (Unification ns) -> m (Unification ns)
mx /\ my = do
  x <- mx
  case x of
    Error e => pure $ Error e
    AreDifferent => pure AreDifferent
    AreSame => my
    DontKnow => pure $ DontKnow

-- Disjunction of unification outcomes (fully monadic version)
public export
(\/) : (Monad m) => m (Unification ns) -> m (Unification ns) -> m (Unification ns)
mx \/ my = do
  x <- mx
  case x of
    -- errors always propagate, even in disjunction, because otherwise we might
    -- partially solve a problem and then fail, then continue in an alternative branch
    Error e => pure $ Error e
    AreSame => pure AreSame
    AreDifferent => my
    DontKnow => my

-- Solve a unification problem if possible, and return an appropriate outcome
solve : HasMetas m => Size ns
  -> MetaVar
  -> Spine ar (Term Value) ns
  -> Term Value ns
  -> m sm (Unification ns)
solve s m sp t = canSolve >>= \case
  Val SolvingAllowed => solveProblem s (MkFlex m sp) t >>= \case
    Left err => pure $ Error {under = []} err
    Right () => pure AreSame
  Val SolvingNotAllowed => pure DontKnow

-- Basic implementations

public export
HasMetas m => Unify m sm Lvl Lvl where
  unifyImpl s l l' = ifAndOnlyIf (decEq l l') (\Refl => pure AreSame)

public export
(HasMetas m, Unify m sm val val') => Unify m sm (Spine as val) (Spine as' val') where
  unifyImpl s [] [] = pure AreSame
  unifyImpl s (x :: xs) (y :: ys) = unify s x y /\ unify s xs ys
  unifyImpl s _ _ = pure AreDifferent

-- Note: a lot of the intermediate unification implementations might return
-- DontKnow for things that are actually the same--they do not actually
-- perform any reductions for a proper check. In other words they are quite
-- conservative.
--
-- For example, the LazyValue unification does not try to reduce lazy apps,
-- it just returns DontKnow if they mismatch. It is up to the caller to then
-- perform the appropriate reduction. This also includes all `normalised` (but
-- not simplified) things.
--
-- All such conservative operations are never allowed to solve metavariables.

HasMetas m => Unify m sm (Term Value) (Term Value)

-- Unification outcome depends on reducibility
--
-- Must also be in the same stage to be unifiable.
{r, r' : Reducibility} -> HasMetas m => Unify m sm (Binder md r Value n) (Binder md r' Value n') where
  unifyImpl _ (BindLam _) (BindLam _) = pure AreSame
  unifyImpl s (BindLet _ tyA a) (BindLet _ tyB b) = noSolving ((unify s tyA tyB /\ unify s a b) \/ pure DontKnow)
  unifyImpl s (BindPi _ a) (BindPi _ b) = unify s a b
  unifyImpl {r = Rigid} {r' = Rigid} _ _ _ = pure AreDifferent
  unifyImpl _ _ _ = pure DontKnow

HasMetas m => Unify m SolvingNotAllowed (Variable Value) (Variable Value) where
  unifyImpl s (Level l) (Level l') = unify s l l'

{r, r' : Reducibility} -> HasMetas m => Unify m sm (Binding md r Value) (Binding md r' Value) where
  unifyImpl s (Bound md bindA (Closure {n = n} envA tA)) (Bound md bindB (Closure envB tB))
    -- unify the binders
    = unify s bindA bindB
      -- unify the bodies, retaining the name of the first binder (kind of arbirary..)
      /\ (escapeBinder (displayIdent bindA) <$> unify {lhs = Term Value} {rhs = Term Value} (SS s)
          (eval (lift s envA) tA)
          (eval (lift s envB) tB))

{hk : PrimitiveClass} -> HasMetas m =>
  Unify m sm (PrimitiveApplied hk Value Simplified) (PrimitiveApplied hk Value Simplified) where
    unifyImpl s (SimpApplied {r = PrimIrreducible} p sp) (SimpApplied {r = PrimIrreducible} p' sp')
      = ifAndOnlyIfHack (primEq p p') (\Refl => unify s sp sp')
    unifyImpl s (SimpApplied p sp) (SimpApplied p' sp')
      = noSolving (inCase (primEq p p') (\Refl => unify s sp sp') \/ pure DontKnow)

{hk : PrimitiveClass} -> HasMetas m =>
  Unify m SolvingNotAllowed (PrimitiveApplied hk Value Normalised) (PrimitiveApplied hk Value Normalised) where
    -- conservative
    unifyImpl s (LazyApplied p sp gl) (LazyApplied p' sp' gl')
      = inCase (primEq p p') (\Refl => unify s sp sp') \/ pure DontKnow

HasMetas m => Unify m SolvingNotAllowed (Head Value Simplified) (Head Value Simplified) where
  -- conservative for meta solutions
  unifyImpl s (ValVar v) (ValVar v') = unify s v v'
  unifyImpl s (ValMeta m) (ValMeta m') = inCase (decToSemiDec (decEq m m')) (\Refl => pure AreSame)
  unifyImpl s (PrimNeutral p) (PrimNeutral p') = unify s p p'
  unifyImpl s _ _ = pure DontKnow

HasMetas m => Unify m sm (HeadApplied Value Simplified) (HeadApplied Value Simplified) where
  -- will never retry from this so it's fine to say DontKnow in the end
  unifyImpl s (h $$ sp) (h' $$ sp') = (noSolving (unify s h h') /\ unify s sp sp') \/ pure DontKnow

HasMetas m => Unify m SolvingNotAllowed (Head Value Normalised) (Head Value Normalised) where
  -- conservative
  unifyImpl s (ObjCallable a) (ObjCallable a') = unify s a a'
  unifyImpl s (ObjLazy a) (ObjLazy b) = unify s a b
  unifyImpl s (ValDef v) (ValDef v') = unify s v v'
  unifyImpl s (PrimNeutral p) (PrimNeutral p') = noSolving (unify s p p')
  unifyImpl _ _ _ = pure DontKnow

HasMetas m => Unify m SolvingNotAllowed (HeadApplied Value Normalised) (HeadApplied Value Normalised) where
  -- conservative
  unifyImpl s (h $$ sp) (h' $$ sp') = (unify s h h' /\ unify s sp sp') \/ pure DontKnow

HasMetas m => Unify m SolvingNotAllowed LazyValue LazyValue where
  -- conservative
  unifyImpl s (LazyApps h _) (LazyApps h' _) = unify s h h' \/ pure DontKnow
  unifyImpl s (LazyPrimNormal p) (LazyPrimNormal p') = unify s p p'
  unifyImpl _ _ _ = pure DontKnow

-- Finally, term unification
export
[unifyValues] (HasMetas m) => Unify m sm (Term Value) (Term Value) where
  resolveLhs = resolveMetas
  resolveRhs = resolveMetas

  unifyImpl s (MtaCallable m) (MtaCallable m') = unify s m m'
  unifyImpl s (SimpPrimNormal p) (SimpPrimNormal p') = unify s p p'
  unifyImpl s (SimpObjCallable o) (SimpObjCallable o') = unify s o o'
  unifyImpl s (RigidBinding md r) (RigidBinding md' r') = ifAndOnlyIf (decEq md md') (\Refl => unify s r r')

  -- Solve metas
  unifyImpl s a (SimpApps (ValMeta m' $$ sp')) = solve s m' sp' a
  unifyImpl s (SimpApps (ValMeta m $$ sp)) b = solve s m sp b

  -- glued terms can reduce further
  unifyImpl s (Glued a) (Glued b) = noSolving (unify s a b) \/ unify s (simplified a) (simplified b)
  unifyImpl s a (Glued b) = unify s a (simplified b)
  unifyImpl s (Glued a) b = unify s (simplified a) b

  -- simplified (rigid) applications
  unifyImpl s (SimpApps a) (SimpApps a') = unify s a a'
  unifyImpl _ (SimpApps _) _ = pure DontKnow
  unifyImpl _ _ (SimpApps _) = pure DontKnow

  -- everything else is different
  unifyImpl _ _ _ = pure AreDifferent
