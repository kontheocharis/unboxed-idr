-- Typechecking combinators for the core language.
module Core.Typechecking

import Utils
import Common
import Data.Singleton
import Data.DPair
import Core.Syntax
import Core.Base
import Core.Evaluation
import Core.Metavariables
import Core.Unification

%default covering

-- Typechecking modes
data TcMode : Type where
  -- Check against a type, produce an elaborated term
  Check : TcMode
  -- Infer to produce an elaborated term and type
  Infer : TcMode

-- Typechecking errors, context-aware
data TcErrorAt : Ctx -> Type where
  -- An error arising from unification
  WhenUnifying : Val ns -> Val ns -> Unification ns -> TcErrorAt ns
  -- Mismatching pi modes
  WrongPiMode : PiMode -> ValTy ns -> TcErrorAt ns
  -- Cannot infer stage
  CannotInferStage : TcErrorAt ns
  -- Cannot find a name
  UnknownName : Name -> TcErrorAt ns

-- A goal is a hole in a context.
record Goal where
  constructor MkGoal

  -- The context in which the goal exists
  {0 conNs : Ctx}
  ctx : Con ValTy conNs

  -- The actual hole term and its type
  hole : Expr Syntax Value conNs

  -- The name of the goal hole, if given
  name : Maybe Name

-- Context for typechecking
record Context (ns : Ctx) where
  constructor MkContext
  -- All the identifiers in scope
  idents : Singleton ns
  -- The current context of types
  con : Con ValTy ns
  -- The definitions in the context
  --
  -- This is an endomorphism of `con`; bindings are mapped to their level, and
  -- definitions are mapped to their value.
  defs : Sub ns Val ns
  -- The stages of the definitions in the context
  stages : Con (const Stage) ns
  -- The size of the context, for quick access
  size : Size ns
  -- The bound variables in the context, in the form of a spine ready to be applied
  -- to a metavariable.
  binds : Exists (\ar => Spine ar (ValTy) ns)

-- Find a name in the context
lookup : Context ns -> Name -> Maybe (Idx ns)
lookup ctx n = findIdx ctx.idents n
  where
    findIdx : forall ns . Singleton ns -> Name -> Maybe (Idx ns)
    findIdx (Val [<]) n = Nothing
    findIdx (Val (ns :< (m, n'))) n = case n == n' of
      True => Just IZ
      False => do
        idx <- findIdx (Val ns) n
        pure $ IS idx

-- Packaging an error with its context
record TcError where
  constructor MkTcError
  {0 conNs : Ctx}
  -- The context in which the error occurred
  con : Context conNs
  -- The location of the error in the source file
  loc : Loc
  -- The error itself
  err : TcErrorAt conNs


-- Add a potentially self-referencing definition to the context.
addToContext : (isBound : Bool) -> (n : Ident) -> Stage -> ValTy ns -> Val (ns :< n) -> Context ns -> Context (ns :< n)
addToContext isBound n stage ty tm (MkContext (Val idents) con defs stages size (Evidence ar bounds)) =
  MkContext
    (Val (idents :< n)) (con :< ty) (defs . Drop Id :< tm) (stages :< stage) (SS size)
    (if isBound then (Evidence (ar ++ [n]) $ wk bounds ++ [tm]) else (Evidence ar $ wk bounds))

-- Add a definition to the context that lazily evaluates to its value.
define : (n : Ident) -> Expr Value Value ns -> Context ns -> Context (ns :< n)
define n rhs ctx =
  addToContext False n rhs.stage rhs.ty (Glued (LazyApps (ValDef (Level (lastLvl ctx.size)) $$ []) (wk rhs.tm))) ctx

-- Add a binding with no value to the context.
bind : (n : Ident) -> Annot Value ns -> Context ns -> Context (ns :< n)
bind n annot ctx = addToContext True n annot.stage annot.ty (varLvl (lastLvl ctx.size)) ctx

-- Typechecking has access to metas
interface (Monad m) => HasTc m where
  -- Explicit instance of metas so that the resolution doesn't die..
  metas : HasMetas (const m)

  -- Throw a typechecking error
  tcError : Context ns -> TcErrorAt ns -> m a

  -- Set the current typechecking location in the source file
  enterLoc : Loc -> m a -> m a

  -- Add a user goal
  addGoal : Maybe Name -> Expr Syntax Value ns -> Context ns -> m ()

  -- Get all the goals that have been seen
  getGoals : m (SnocList Goal)

-- This is the type over which we build the typechecking combinators.
--
-- `TcOp m md ns` is a typechecking operation in mode md.
--
-- It can be executed to produce an elaborated expression, depending on what `md` is.
0 TcOp : (md : TcMode) -> (0 m : Type -> Type) -> Ctx -> Type
TcOp Check m ms = Annot Value ms -> m (Tm ms)
TcOp Infer m ms = (s : Maybe Stage) -> m (ExprAtMaybe s Syntax Value ms)

-- Typechecking in a specific context
0 TcAt : (md : TcMode) -> (0 m : Type -> Type) -> Ctx -> Type
TcAt md m ns = Context ns -> TcOp md m ns

-- Typechecking in any context
--
-- This is what is mostly used to work with, since a lot of the time we don't know which
-- context we will check in ahead of time (due to things like inserted lambdas).
0 Tc : (md : TcMode) -> (0 m : Type -> Type) -> Type
Tc md m = forall ns . TcAt md m ns

-- Map a parametric monadic operation over Tc.
public export
intercept : HasTc m => (forall a . m a -> m a) -> {md : TcMode} -> Tc md m -> Tc md m
intercept f {md = Check} x = \ctx, as => f (x ctx as)
intercept f {md = Infer} x = \ctx, s => f (x ctx s)

-- Some useful shorthands

resolve : HasTc m => Val ns -> m (Val ns)
resolve x = resolveGlueAndMetas {sm = SolvingAllowed} @{metas} x

evaluate : Context ns -> Tm ns -> Val ns
evaluate ctx t = eval ctx.defs t

reify : Context ns -> Val ns -> Tm ns
reify ctx v = quote ctx.size v

-- Create a fresh metavariable
freshMetaVal : HasTc m => Context ns -> ValTy ns -> Stage -> m (Val ns)
freshMetaVal ctx ty s = do -- @@Todo: use type
  m <- newMeta {sm = SolvingAllowed} @{metas}
  -- Get all the bound variables in the context, and apply them to the
  -- metavariable. This will later result in the metavariable being solved as a
  -- lambda of all these variables.
  pure $ SimpApps (ValMeta m $$ snd ctx.binds)

-- Create a fresh metavariable and quote it
freshMeta : HasTc m => Context ns -> ValTy ns -> Stage -> m (Tm ns)
freshMeta ctx ty s = reify ctx <$> freshMetaVal ctx ty s

-- Insert all lambdas implicit lambdas in a type-directed manner, without regard
-- for what the expression is.
insertAll : (HasTc m) => Context ns -> m (Expr Syntax Value ns) -> m (Expr Syntax Value ns)

-- Insert all lambdas implicit lambdas in a type-directed manner, unless the given expression is a
-- matching implicit lambda.
insert : (HasTc m) => Context ns -> m (Expr Syntax Value ns) -> m (Expr Syntax Value ns)

-- Stage-aware `insert`.
insertAt : (HasTc m) => Context ns -> (s : Stage) -> m (ExprAt s Syntax Value ns) -> m (ExprAt s Syntax Value ns)

-- Insert until a given name is reached.
insertUntil : (HasTc m) => Context ns -> Name -> m (Expr Syntax Value ns) -> m (Expr Syntax Value ns)

-- Ensure that the given `Maybe Stage` is `Just _`, eliminating with the
-- supplied method.
ensureKnownStage : HasTc m
  => (Context ns -> (s : Stage) -> m (ExprAt s d d' ns))
  -> Context ns
  -> (ms : Maybe Stage)
  -> m (ExprAtMaybe ms d d' ns)
ensureKnownStage f ctx (Just s) = f ctx s
ensureKnownStage f ctx Nothing = tcError ctx CannotInferStage

-- Try to adjust the stage of an expression.
tryAdjustStage : (HasTc m) => Context ns -> Expr Syntax Value ns -> (s : Stage) -> m (Maybe (ExprAt s Syntax Value ns))

-- Adjust the stage of an expression.
adjustStage : (HasTc m) => Context ns -> Expr Syntax Value ns -> (s : Stage) -> m (ExprAt s Syntax Value ns)

adjustStageIfNeeded : (HasTc m) => Context ns -> Expr Syntax Value ns -> (s : Maybe Stage) -> m (ExprAtMaybe s Syntax Value ns)
adjustStageIfNeeded ctx expr Nothing = pure $ MkExpr expr.tm expr.ty expr.stage
adjustStageIfNeeded ctx expr (Just s) = adjustStage ctx expr s

-- Coerce an expression to a given type.
coerce : (HasTc m) => Expr Syntax Value ns -> Annot Value ns -> m (Tm ns)

-- Unify two values in the given context.
--
-- Succeeds if the unification says `AreSame`.
unify : HasTc m => Context ns -> Val ns -> Val ns -> m ()
unify ctx a b = unify {sm = SolvingAllowed} @{unifyValues @{metas}} ctx.size a b >>= \case
  AreSame => pure ()
  failure => tcError ctx $ WhenUnifying a b failure

-- Force a typechecking operation to be in checking mode. This might involve unifying with an
-- inferred type.
check : HasTc m => Tc Infer m -> Tc Check m
check f = \ctx, annot => do
  result <- insertAt ctx annot.stage $ f ctx (Just annot.stage)
  unify ctx annot.ty result.ty
  pure result.tm

-- Evaluate a closure with a extended environment
evalClosure : Context ns -> Body Value n ns -> Term Value (ns :< n')
evalClosure ctx (Closure env body) = eval (lift ctx.size env) body

-- Close a syntactic term into a closure.
public export
close : Context ns -> Tm (ns :< n) -> Body Value n ns
close ctx ty = Closure (id ctx.size) ty


-- Insert (some kind of an implicit) lambda from the given information.
--
-- This adds the binder to the subject and `recurses`, yielding a lambda with the
-- given Pi type.
insertLam : HasTc m => Context ns
  -> (piStage : Stage)
  -> (piIdent : Ident)
  -> (bindTy : ValTy ns)
  -> (body : Body Value piIdent ns)
  -> (subject : Tc Check m)
  -> m (ExprAt piStage Syntax Value ns)
insertLam ctx piStage piIdent bindTy body subject = do
  let b = evalClosure ctx body
  s <- subject (bind piIdent (MkAnnot bindTy piStage) ctx) (MkAnnot b piStage)
  pure $ MkExprAt (sLam piStage piIdent s) (vPi piStage piIdent bindTy body)

-- The type of the callback that `ifForcePi` calls when it finds a matching
-- type.
0 ForcePiCallback : (r : Type) -> Ctx -> Type
ForcePiCallback r ns = (resolvedPi : ValTy ns)
  -> (piStage : Stage)
  -> (piIdent : Ident)
  -> (a : ValTy ns)
  -> (b : Body Value piIdent ns)
  -> r

-- Given a `potentialPi`, try to match it given that we expect something in
-- `mode` and `stage`.
--
-- If it matches, call `ifMatching` with the appropriate information, otherwise
-- call `ifMismatching` with the appropriate information.
ifForcePi : (HasTc m) => Context ns
  -> (mode : PiMode)
  -> (stage : Stage)
  -> (potentialPi : ValTy ns)
  -> (ifMatching : ForcePiCallback (m r) ns)
  -> (ifMismatching : ForcePiCallback (m r) ns)
  -> m r
ifForcePi ctx mode stage potentialPi ifMatching ifMismatching
  = resolve potentialPi >>= \case
    resolvedPi@(RigidBinding piStage (Bound piStage (BindPi piIdent a) b)) =>
      -- We got a pi
      if fst piIdent == mode && piStage == stage
        then ifMatching resolvedPi piStage piIdent a b
        else ifMismatching resolvedPi piStage piIdent a b
    resolvedPi => do
      -- Did not get a pi, try to construct a pi based on the info we have and
      -- unify it with the potential pi.
      let univ = evaluate ctx $ typeForStage stage
      a <- freshMetaVal ctx univ stage
      let piIdent = (mode, "x")
      b <- close ctx <$> freshMeta (bind piIdent (MkAnnot a stage) ctx) (wk univ) stage
      let createdPi = vPi stage piIdent a b
      unify ctx resolvedPi createdPi
      ifMatching createdPi stage piIdent a b

-- Infer the given job as a type, also inferring its stage in the process.
inferAnnot : HasTc m => Context ns -> Tc Infer m -> m (Annot Value ns)
inferAnnot ctx ty = do
  MkExpr ty univ stage <- ty ctx Nothing
  unify ctx univ (evaluate ctx $ typeForStage stage)
  let vty = evaluate ctx ty
  pure $ MkAnnot vty stage

-- Infer a lambda at the given stage, with the given binder name and type.
inferLam : HasTc m => Context ns
  -> (stage : Stage)
  -> (n : Ident)
  -> (a : ValTy ns)
  -> Tc Infer m -> m (ExprAt stage Syntax Value ns)
inferLam ctx stage lamIdent a body = do
  MkExprAt body' bTy <- body (bind lamIdent (MkAnnot a stage) ctx) (Just stage)
  let b = close ctx (quote (SS ctx.size) bTy)
  pure $ MkExprAt (sLam stage lamIdent body') (vPi stage lamIdent a b)

-- Typechecking combinator for lambdas.
tcLam : HasTc m => (md : TcMode)
  -> (n : Ident)
  -> (bindTy : Maybe (Tc Infer m))
  -> (body : Tc md m)
  -> Tc md m
tcLam Check lamIdent bindTy body = \ctx, annot@(MkAnnot ty stage) => do
  -- We must check that the type we have is a pi
  ifForcePi ctx (fst lamIdent) stage ty
    (\_, piStage, piIdent, a, b => do
      -- Great, it is a pi. Now first reconcile this with the annotation type
      -- of the lambda.
      a : Annot Value ns <- case bindTy of
        Nothing => pure $ MkAnnot a piStage
        Just bindTy => do
          bindTy' <- evaluate ctx <$> check bindTy ctx (MkAnnot (evaluate ctx $ typeForStage piStage) piStage)
          unify ctx a bindTy'
          pure $ MkAnnot bindTy' piStage
      -- Then check the body with the computed annotation type.
      body' <- body (bind lamIdent a ctx) (MkAnnot (evalClosure ctx b) piStage)
      pure $ sLam piStage lamIdent body'
    )
    (\resolvedPi, piStage, piIdent, a, b => case fst piIdent of
      -- It wasn't the right kind of pi; if it was implicit, insert a lambda
      Implicit => (.tm) <$> insertLam ctx piStage piIdent a b (tcLam Check lamIdent bindTy body)
      -- Otherwise, we have the wrong kind of pi.
      _ => tcError ctx (WrongPiMode (fst piIdent) resolvedPi)
    )
tcLam Infer lamIdent bindTy body = \ctx, stage => do
  -- We are not given a type to check against...
  case stage of
    Nothing => case bindTy of
      -- We are not even given a stage, and we aren't gonna guess because that
      -- might be wrong.
      Nothing => tcError ctx CannotInferStage
      -- We have at least a type, so we can deduce the stage from that.
      Just bindTy => do
        MkAnnot a stage <- inferAnnot ctx bindTy
        packStage <$> inferLam ctx stage lamIdent a body
    Just stage => case bindTy of
      -- We have a stage, but no type, so just instantiate a meta..
      Nothing => do
        a <- freshMetaVal ctx (evaluate ctx $ typeForStage stage) stage
        inferLam ctx stage lamIdent a body
      Just bindTy => do
        -- We have a stage and a type. For this, we infer with the type, and
        -- then adjust for the stage later. We shouldn't call inferLam directly
        -- because we don't know that the stage is valid for the given type yet.
        res <- tcLam Infer lamIdent (Just bindTy) body ctx Nothing
        adjustStage ctx res stage

-- Infer a tuple, given by a list of named terms
tcTuple : HasTc m => List (Ident, Tc Check m) -> Tc Check m

-- Infer a variable, by looking up in the context
tcVar : HasTc m => Name -> Tc Infer m
tcVar n = \ctx, stage' => case lookup ctx n of
    Nothing => tcError ctx $ UnknownName n
    Just idx => do
      let tm = SynApps (SynVar (Index idx) $$ [])
      let ty = ctx.con.index idx
      let stage = ctx.stages.index idx
      adjustStageIfNeeded ctx (MkExpr tm ty stage) stage'

-- Infer or check a user-supplied hole
--
-- We should at least know the stage of the hole. User holes are added to the
-- list of goals, which can be displayed after typechecking.
tcHole : HasTc m => {md : TcMode} -> Maybe Name -> Tc md m
tcHole {md = Check} name = \ctx, (MkAnnot ty stage) => do
  mta <- freshMeta ctx ty stage
  addGoal name (MkExpr mta ty stage) ctx
  pure mta
tcHole {md = Infer} name = ensureKnownStage $ \ctx, stage => do
  tyMta <- freshMetaVal ctx (evaluate ctx $ typeForStage stage) stage
  mta <- freshMeta ctx tyMta stage
  addGoal name (MkExpr mta tyMta stage) ctx
  pure $ MkExprAt mta tyMta

checkSpine : HasTc m => List (Ident, Tc Check m) -> Tel ar (Annot Value) ns -> m (Spine ar Tm ns)

tcPrimNorm : HasTc m => {r : PrimitiveReducibility} -> Primitive PrimNorm r ar -> List (Ident, Tc Check m) -> Tc Infer m
tcPrimNorm {r} p args = \ctx, stage => do
  let (pParams, pRet) = primTy p
  sp <- checkSpine args (evalTel ctx.size ctx.defs pParams)
  adjustStageIfNeeded ctx
    (MkExpr (SynPrimNormal (p $$ sp)) (evaluate (?ctx) $ ?qa) pRet.stage)
    stage


-- TODO:
--
-- Let
-- Let rec
-- Pi
-- Universe
-- Code, quote, splice
-- Rest of primitives
-- Sigma
-- Pairs
-- Projection
-- Literals
