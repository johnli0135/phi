module Core where

import Data.Set (Set); import qualified Data.Set as S
import Data.Map.Strict (Map); import qualified Data.Map.Strict as M

import qualified Data.List as L
import Data.Semigroup
import qualified Data.Foldable as F
import Data.Bifunctor
import Data.Functor
-- import Data.Functor.Foldable
-- import Data.Functor.Foldable.TH
-- import Data.Functor.Classes
-- import Data.Functor.Compose
import Control.Monad
import Control.Monad.Except
import Control.Monad.State.Strict
import Control.Monad.Reader
import Control.Monad.Writer.Strict
-- import Control.Monad.Trans.Maybe
import Control.Applicative
-- import Text.Show.Deriving
-- 
-- import Data.SBV
-- import qualified Data.SBV.Internals as SBVI
-- 
import Data.String (IsString (..))
import Data.DList (DList); import qualified Data.DList as D

import Data.Char
import Data.Void
import Text.Megaparsec (ParsecT, MonadParsec)
import qualified Text.Megaparsec as P
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import Util

import Data.HList.CommonMain
import Control.Lens

-- -------------------- Object language --------------------

-- Primitives
data Prim
  = Add | Sub | Mul | Div
  deriving (Eq, Ord, Show)

-- Primitive types
data PTy
  = I Word
  | Half | Float | Double | FP128
  | Ptr Ty
  deriving (Eq, Ord, Show)

-- Types
data Ty
  = Void
  | PTy PTy
  | Vec Word PTy
  | Arr Word Ty
  | Tup [Ty]
  | FPtr [Ty] Ty
  deriving (Eq, Ord, Show)

-- LLVM has 3 ways of reading substructures:
-- - extractvalue: works on structs or arrays with constant offset
-- - extractelement: works on vectors with variable offset
-- - gep: works on ptrs with arbitrary paths (struct offsets must be i32)
-- LLVM's version of C's a[i] is gep + load.

-- Access paths
type Path a = [Step a]
data Step a
  = Proj a Word -- extractvalue struct: e.n, n const
  | ElemA a Word -- extractvalue array: e.[n], n const
  | Elem (Exp a) -- extractelement: e<e>
  | Index (Exp a) -- gep offset: e[e]
  deriving (Eq, Ord, Show)

type Var = Word
type Width = Word

-- Local function definition
data Func a = Func a Var [(a, Var, Ty)] Ty (Exp a) deriving (Eq, Ord, Show)

-- Expressions
data Arm a = Maybe Integer :=> Exp a deriving (Eq, Ord, Show)
data Exp a
  -- Primitives
  = Var a Var
  | Int a Integer Width
  | Ann a (Exp a) Ty
  | Prim a Prim [Exp a]
  | Coerce a (Exp a) Ty
  | Let a Var Ty (Exp a) (Exp a)
  -- Control flow / name binding
  | Call a (Exp a) [Exp a]
  | Case a (Exp a) [Arm a]
  | Rec a [Func a] (Exp a) -- Function bundle
  -- Aggregates
  | Tuple a [Exp a]
  | Vector a [Exp a]
  | Gep a (Exp a) (Path a) -- &e path (GEP)
  | Load a (Exp a) (Path a) -- e path (GEP+load, extractvalue, extractelement)
  | Store a (Exp a) (Path a) (Exp a) (Exp a) -- e path <- e; e (GEP+store)
  | Update a (Exp a) (Path a) (Exp a) -- e with path = e (insertvalue, insertelement)
  deriving (Eq, Ord, Show)

-- Since this is LLVM and not λ-calculus, every function must satisfy some conditions
-- so that they can be implemented as SSA blocks using φ-nodes instead of closures.
-- - A function f "needs" variable x if, assuming UB,
--   (1) x ∈ FV(body of f) or
--   (2) f calls g, g needs x, and x ∉ BV(body of f).
-- - All calls to functions which need variables must be in tail position.
-- - These tail calls will become `br` instructions and the corresponding functions
--   will become SSA blocks with φ-nodes.
-- - Functions which don't need variables become global functions.
--   Technically, these functions can also become SSA blocks if only called in tail
--   position, but that probably doesn't buy much.

-- -------------------- Some boilerplate to work with annotations --------------------

makeLabelable "typ loc"

type ParseAnn = Record '[Tagged "loc" P.SourcePos]
type TyAnn = Record '[Tagged "typ" Ty, Tagged "loc" P.SourcePos]

raise a e = throwError (a ^. loc, e)

-- -------------------- Doc formatting utils --------------------

type Str = DList Char -- For efficient catenation

-- Indentation + φ sets as input
-- Phi sets represented as f ↦ x ↦ actuals
type Usages = Map Var (Map Var (Set Var))
type Doc = Reader (Str, Usages) Str
deriving instance Semigroup a => Semigroup (Reader r a)
deriving instance Monoid a => Monoid (Reader r a)

show' :: Show a => a -> Str
show' = D.fromList . show

show'' :: Show a => a -> Doc
show'' = pure . show'

runDoc :: Doc -> Usages -> String
runDoc c usages = D.toList $ c `runReader` ("", usages)

instance IsString Doc where fromString = pure . D.fromList

indent :: Doc -> Doc
indent = local (first ("  " <>))

line :: Str -> Doc
line l = reader $ \ (s, _) -> s <> l <> "\n"

line' :: Doc -> Doc
line' l = reader $ \ r@(s, _) -> s <> runReader l r <> "\n"

calate :: Doc -> [Doc] -> Doc
calate sep ds = F.fold (L.intersperse sep ds)

commaSep :: [Doc] -> Doc
commaSep = calate ", "

class PP a where pp :: a -> Doc

instance PP PTy where
  pp = \case
    I w -> "i" <> show'' w
    Half -> "half"
    Float -> "float"
    Double -> "double"
    FP128 -> "FP128"
    Ptr t -> "&" <> pp t

instance PP Ty where
  pp = \case
    Void -> "void"
    PTy t -> pp t
    Vec n t -> "<" <> show'' n <> " x " <> pp t <> ">"
    Arr n t -> "[" <> show'' n <> " x " <> pp t <> "]"
    Tup ts -> "{" <> commaSep (map pp ts) <> "}"
    FPtr ts t -> "(fun (" <> commaSep (map pp ts) <> ") -> " <> pp t <> ")"

instance PP (Func a) where
  pp (Func _ f xts t e) =
    let xts' = map (\ (_, x, t) -> show'' x <> ": " <> pp t) xts in
    show'' f <> "(" <> commaSep xts' <> "): " <> pp t <> " =" <> indent (pp e)

instance PP Prim where
  pp = \case
    Add -> "add"
    Mul -> "mul"
    Sub -> "sub"
    Div -> "div"

instance PP (Exp a) where pp = undefined
--   pp = \case
--     AVar _ x -> show'' x
--     AInt _ i w -> show'' i <> "i" <> show'' w
--     ATuple _ es -> "{" <> commaSep (map pp es) <> "}"
--     AVector _ es -> "{" <> commaSep (map pp es) <> "}"
--     AUpdate _ e1 p e2 -> pp e1 <> " {" <> calate "." (show'' <$> p) <> " = " <> pp e2 <> "}"
--     ACoerce _ e t -> pp e <> " as " <> pp t
--     ABinop _ e1 o e2 -> "(" <> pp e1 <> " " <> pp o <> " " <> pp e2 <> ")"
--     ALet _ x t e1 e -> F.fold
--       [ line' $ "let " <> show'' x <> ": " <> pp t <> " = "
--       , indent (pp e1)
--       , line $ " in "
--       , pp e
--       ]
--     ACall _ e es -> pp e <> "(" <> commaSep (map pp es) <> ")"
--     AGep _ e p -> "&" <> pp e -- TODO
--     ALoad _ e -> "*" <> pp e
--     AStore _ d s e -> F.fold
--       [ line' $ pp d <> " := " <> pp s <> ";"
--       , pp e
--       ]
--     ARec _ fs e -> undefined -- TODO
--     ACase _ e d pes -> undefined -- TODO
--     AAnn _ e ty -> "(" <> pp e <> " : " <> pp ty <> ")"
-- 
-- -- -------------------- Variables --------------------
-- 
-- -- Generic fold over variables
-- foldVars :: Monoid m => (Var -> m) -> Exp a -> m
-- foldVars f = \case
--   AVar _ x -> f x
--   AInt _ _ _ -> mempty
--   ATuple _ es -> foldMap (foldVars f) es
--   AVector _ es -> foldMap (foldVars f) es
--   AUpdate _ e1 _ e2 -> foldVars f e1 <> foldVars f e2
--   ACoerce _ e _ -> foldVars f e
--   ABinop _ e1 _ e2 -> foldVars f e1 <> foldVars f e2
--   ALet _ x _ e1 e -> f x <> foldVars f e1 <> foldVars f e
--   ACall _ e es -> foldVars f e <> foldMap (foldVars f) es
--   AGep _ e p -> foldVars f e -- TODO
--   ALoad _ e -> foldVars f e
--   AStore _ d s e -> foldVars f d <> foldVars f s <> foldVars f e
--   ARec _ fs e ->
--     foldMap (\ (AFunc _ f' xts _ e) -> f f' <> foldMap (f . fst) xts <> foldVars f e) fs <>
--     foldVars f e
--   ACase _ e d pes ->
--     foldVars f e <> foldVars f d <> foldMap (\ (_ :=> e) -> foldVars f e) pes
--   AAnn _ e _ -> foldVars f e
-- 
-- -- Smallest variable v such that {v + 1, v + 2, ..} are all unused
-- maxUsed :: Exp a -> Var
-- maxUsed = getMax . foldVars Max
-- 
-- -- Used variables
-- uv :: Exp a -> Set Var
-- uv = foldVars S.singleton
-- 
-- -- Rename bound variables for unique bindings
-- ub :: Exp a -> Exp a
-- ub p = go M.empty p `evalState` maxUsed p where
--   go σ = \case
--     AVar a x -> return $ AVar a (σ ! x)
--     AInt a i w -> return $ AInt a i w
--     ATuple a es -> ATuple a <$> mapM (go σ) es
--     AVector a es -> AVector a <$> mapM (go σ) es
--     AUpdate a e1 p e2 -> AUpdate a <$> go σ e1 <*> pure p <*> go σ e2
--     ACoerce a e t -> ACoerce a <$> go σ e <*> pure t
--     ABinop a e1 (·) e2 -> ABinop a <$> go σ e1 <*> pure (·) <*> go σ e2
--     ALet a x t e1 e -> do x' <- gen; ALet a x' t <$> go σ e1 <*> go (M.insert x x' σ) e
--     ACall a e es -> ACall a <$> go σ e <*> mapM (go σ) es
--     AGep a e p -> AGep a <$> go σ e <*> pure p -- TODO
--     ALoad a e -> ALoad a <$> go σ e
--     AStore a d s e -> AStore a <$> go σ d <*> go σ s <*> go σ e
--     ARec a helpers e -> do
--       let fs = map (\ (AFunc _ f _ _ _) -> f) helpers
--       fs' <- replicateM (length fs) gen
--       let σ' = foldr (uncurry M.insert) σ (zip fs fs')
--       helpers' <- forM helpers $ \ (AFunc a f xts t e) -> do
--         let xs = map fst xts
--         xs' <- replicateM (length xts) gen
--         let σ'' = foldr (uncurry M.insert) σ' (zip xs xs')
--         AFunc a (σ ! f) (zip xs' (map snd xts)) t <$> go σ'' e
--       ARec a helpers' <$> go σ' e
--     ACase a e d pes ->
--       ACase a
--         <$> go σ e <*> go σ d
--         <*> mapM (\ (p :=> e) -> (p :=>) <$> go σ e) pes
--     AAnn a e ty -> AAnn a <$> go σ e <*> pure ty
--   σ ! x = M.findWithDefault x x σ
--   gen = modify' succ *> get
-- 
-- -- -- Free variables
-- -- fvF :: Base Process (Set Var) -> Set Var
-- -- fvF = \case
-- --   HaltF -> S.empty
-- --   NewF x vs -> S.delete x vs
-- --   SendF s d vs -> S.insert s (S.insert d vs)
-- --   RecvF d s vs -> S.insert s (S.delete d vs)
-- --   EvalF x e vs -> foldMap S.singleton e ∪ S.delete x vs
-- --   DoF e vs -> foldMap S.singleton e
-- --   vs :|:$ ws -> vs ∪ ws
-- --   vs :+:$ ws -> vs ∪ ws
-- --   LoopF vs -> vs
-- --   MatchF x (L.unzip -> (xs, vss)) -> S.fromList (x : xs) ∪ F.fold vss
-- --   ForeignF _ vs -> vs
-- -- 
-- -- fv :: Process -> Set Var
-- -- fv = cata fvF
-- -- 

-- -------------------- Type checking --------------------

data TCErr
  = NotInScope Var
  | ExGotShape String Ty
  | ExGot Ty Ty
  | Custom String

instance PP TCErr where
  pp = \case
    NotInScope x -> line $ "Variable not in scope: " <> show' x
    ExGotShape shape ty ->
      line' $ "Expected " <> pure (D.fromList shape) <> " but got " <> pp ty
    ExGot ex got -> line' $ "Expected " <> pp ex <> " but got " <> pp got
    Custom s -> line $ D.fromList s

type TC =
  ExceptT (P.SourcePos, TCErr)
  (Reader
    ( Map Var (Ty, Bool) -- x ↦ (typeof x, x must basic block)
    , Bool -- Whether or not we are in tail position
    ))

runTC' :: TC a -> Map Var (Ty, Bool) -> Bool -> Either (P.SourcePos, TCErr) a
runTC' m r b = runExceptT m `runReader` (r, b)

runTC :: TC a -> Either String a
runTC m = first pretty $ runTC' m M.empty True where
  pretty (pos, err) = P.sourcePosPretty pos ++ ": " ++ runDoc (pp err) M.empty

untail :: TC a -> TC a
untail = local (\ (env, _) -> (env, False))

withBindings :: [Var] -> [Ty] -> [Bool] -> TC a -> TC a
withBindings xs ts bs = local (\ (m, b) -> (M.fromList (zip xs (zip ts bs)) `M.union` m, b))

withBinding :: Var -> Ty -> Bool -> TC a -> TC a
withBinding x t b = local (first $ M.insert x (t, b))

isTail :: TC Bool
isTail = snd <$> ask

find :: ParseAnn -> Var -> TC (Ty, Bool)
find a x = (M.!? x) . fst <$> ask >>= \case
  Just r -> return r
  Nothing -> raise a $ NotInScope x

typeof :: ParseAnn -> Var -> TC Ty
typeof a x = fst <$> find a x

isBB :: ParseAnn -> Var -> TC Bool
isBB a x = snd <$> find a x

check :: Exp ParseAnn -> Ty -> TC (Exp TyAnn)
check exp ty = case exp of
  Case a e pes -> infer e >>= \case
    (PTy (I _), e') -> do
      pes' <- mapM (\ (p :=> e) -> (p :=>) <$> check e ty) pes
      return $ Case (typ .==. ty .*. a) e' pes'
    (ty, _) -> raise a $ ExGotShape "integer" ty
  exp@(anno -> a) -> infer exp >>= \case
    (ty', exp')
      | ty' == ty -> return exp'
      | otherwise -> raise a $ ExGot ty ty'
  where
    anno = \case
      Var a _ -> a
      Int a _ _ -> a
      Ann a _ _ -> a
      Prim a _ _ -> a
      Coerce a _ _ -> a
      Let a _ _ _ _ -> a
      Call a _ _ -> a
      Case a _ _ -> a
      Rec a _ _ -> a

checkNumOp :: ParseAnn -> [Exp ParseAnn] -> TC (Ty, [Exp TyAnn])
checkNumOp a = \case
  [] -> raise a . Custom $ "Expected at least one argument"
  (e:es) -> do
    (t, e') <- infer e
    when (not (numeric t)) . raise a $ ExGotShape "numeric type" t
    es' <- zipWithM check es (repeat t)
    return (t, e':es')
  where
    numeric = \case
      PTy (I _) -> True
      PTy Half -> True
      PTy Float -> True
      PTy Double -> True
      PTy FP128 -> True

checkPrim :: ParseAnn -> [Exp ParseAnn] -> Prim -> TC (Ty, [Exp TyAnn])
checkPrim a es = \case
  Add -> checkNumOp a es
  Mul -> checkNumOp a es
  Sub -> checkNumOp a es
  Div -> checkNumOp a es

var :: ParseAnn -> Var -> TC (Ty, Exp TyAnn)
var a x = do
  ty <- typeof a x
  return $ (ty, Var (typ .==. ty .*. a) x)

infer :: Exp ParseAnn -> TC (Ty, Exp TyAnn)
infer = \case
  Var a x -> var a x
  Int a i w -> let t = PTy (I w) in return (t, Int (typ .==. t .*. a) i w)
  Ann _ e ty -> (ty, ) <$> check e ty
  Prim a p es -> do
    (t, es') <- checkPrim a es p
    return (t, Prim (typ .==. t .*. a) p es')
  Coerce a e ty -> do
    (_, e') <- infer e
    return (ty, Coerce (typ .==. ty .*. a) e' ty)
  Let a x t e1 e -> do
    e1' <- check e1 t
    (ty, e') <- withBinding x t False (infer e)
    return (ty, Let (typ .==. ty .*. a) x t e1' e')
  Call a e es -> infer e >>= \case
    (FPtr ts t, e') -> do
      es' <- zipWithM check es ts
      return (t, Call (typ .==. t .*. a) e' es')
    (ty, _) -> raise a $ ExGotShape "function" ty
  Rec a funcs e -> do
    let fs = map (\ (Func _ f _ _ _) -> f) funcs
    let ts = map (\ (Func _ _ axts t _) -> FPtr (map (\ (_, _, t) -> t) axts) t) funcs
    let bbs = fs $> False
    withBindings fs ts bbs $ do
      funcs' <- forM funcs $ \ (Func a f axts t e) -> do
        let xs = map (\ (_, x, _) -> x) axts
        let ts = map (\ (_, _, t) -> t) axts
        let axts' = map (\ (a, x, t) -> (typ .==. Void .*. a, x, t)) axts
        current <- ask
        e' <- withBindings xs ts (ts $> False) (check e t)
        return $ Func (typ .==. Void .*. a) f axts' t e'
      (ty, e') <- infer e
      return (ty, Rec (typ .==. ty .*. a) funcs' e')
--   ATuple a es -> do
--     es' <- mapM infer es
--     return $ ATuple (Tup (map (\ (AnnoTy t) -> t) es'), a) es'
--   AVector a es -> do
--     es' <- mapM infer es
--     return $ AVector (Vec (map (\ (AnnoTy t) -> t) es'), a) es'
--   AUpdate a e1 _ e2 -> undefined -- TODO
--   ACoerce a e t -> ACoerce (t, a) <$> infer e <*> pure t
--   ABinop a e1 o e2@(Anno a2) -> (,) <$> infer e1 <*> infer e2 >>= \case
--     (AnnTy e1' t1, AnnTy e2' t2)
--       | t1 == t2 -> return $ ABinop (t1, a) e1' o e2'
--       | otherwise -> raise a2 $ ExGot t1 t2
--   AGep a e p -> undefined -- TODO
--   ALoad a e -> infer e >>= \case
--     AnnTy e' (Prim (Ptr t)) -> return $ ALoad (t, a) e'
--     AnnoTy ty -> raise a $ ExGotShape "pointer" ty
--   AStore a d s e -> infer d >>= \case
--     AnnTy d' (Prim (Ptr t)) -> do
--       s' <- check s t
--       AnnTy e' ty <- infer e
--       return $ AStore (ty, a) d' s' e'
--     AnnoTy ty -> raise a $ ExGotShape "pointer" ty

-- -- -- -------------------- Code generation utils --------------------
-- -- 
-- -- varG :: Var -> Doc
-- -- varG x = (M.! x) . fst <$> ask >>= \case
-- --   Rbx -> pure "rbx"
-- --   R12 -> pure "r12"
-- --   R13 -> pure "r13"
-- --   R14 -> pure "r14"
-- --   R15 -> pure "r15"
-- --   Spill n -> pure $ "spill" <> show' n
-- -- 
-- -- declG :: Str -> Var -> Doc
-- -- declG ty x = (M.! x) . fst <$> ask >>= \case
-- --   Spill _ -> pure ty <> " " <> varG x
-- --   _ -> varG x
-- -- 
-- -- procG :: Doc -> Doc -> Doc
-- -- procG name body = F.fold
-- --   [ line' ("void " <> name <> "(void) {")
-- --   , indent body
-- --   , indent $ line "asm (\"jmp gt_stop\\t\\n\");"
-- --   , line "}"
-- --   ]
-- -- 
-- -- spillProcG :: Set Var -> Doc -> Doc -> Doc
-- -- spillProcG spilled name body = procG name $ F.fold
-- --   [ line "gt_ch *rsp = (gt_ch *)gt_self()->rsp + 1;"
-- --   , F.fold . for2 [0..] (S.toAscList spilled) $ \ offset x ->
-- --       line' $ "gt_ch " <> varG x <> " = rsp[" <> show'' offset <> "];"
-- --   , body
-- --   ]
-- -- 
-- -- mainG :: Doc -> Doc
-- -- mainG body = F.fold
-- --   [ line "int main(void) {"
-- --   , indent $ F.fold
-- --     [ line "gt_init();"
-- --     , body
-- --     , line "gt_exit(0);"
-- --     ]
-- --   , line "}"
-- --   ]
-- 
-- -- -------------------- Code generation --------------------
-- 
-- varG :: Var -> Doc
-- varG x = "%" <> show'' x
-- 
-- binopG :: Binop -> Doc
-- binopG = \case
--   Add -> "add"
--   Mul -> "mul"
--   Sub -> "sub"
--   Div -> "div"
-- 
-- type Gen =
--   ReaderT (Map Var (Set Var)) -- Rec functions ↦ formals
--   (StateT (Var, Doc, Map Var (Map Var (Set Var))) -- Fresh names, current body, rec function ↦ formal ↦ actuals
--   (Writer Doc)) -- Global definitions
-- 
-- fresh :: Gen Var
-- fresh = get <* modify' succ
-- 
-- gensym :: Doc -> Gen Doc
-- gensym name = ("%" <>) . (name <>) . show'' <$> fresh
-- 
-- voidG :: Doc -> Gen Var
-- voidG instr = do
--   x <- fresh
--   tell (mempty, line' $ instr)
--   return x
-- 
-- instrG :: Doc -> Gen Var
-- instrG instr = do
--   x <- fresh
--   tell (mempty, line' $ varG x <> " = " <> instr)
--   return x
-- 
-- expG :: Has Ty a => Exp a -> Gen Var
-- expG = \case
--   AVar _ x -> return x
--   AInt (π -> ty :: Ty) i _ -> instrG $ "add " <> pp ty <> " 0, " <> show'' i
--   ATuple (π -> ty :: Ty) es -> do
--     let ty' = pp ty
--     p <- fmap varG . instrG $ "alloca " <> ty'
--     r <- instrG $ "load " <> ty' <> ", " <> pp (Prim (Ptr ty)) <> " " <> p
--     acciM es r $ \ i (varG -> r') e@(Anno (π -> t :: Ty)) -> do
--       e' <- varG <$> expG e
--       instrG $ "insertvalue " <> ty' <> " " <> r' <> ", " <> pp t <> " " <> e' <> ", " <> show'' i
--   AVector (π -> ty :: Ty) es -> undefined -- TODO
--   -- AUpdate _ e1 p e2 -> pp e1 <> " {" <> calate "." (show'' <$> p) <> " = " <> pp e2 <> "}"
--   ACoerce _ e t -> undefined -- TODO
--   ABinop (π -> ty :: Ty) e1 o e2 -> do
--     e1' <- varG <$> expG e1
--     e2' <- varG <$> expG e2
--     instrG $ binopG o <> " " <> pp ty <> " " <> e1' <> ", " <> e2'
--   ALet (π -> ty :: Ty) x t e1 e -> do
--     e1' <- varG <$> expG e1
--     let ty' = pp ty
--     p <- fmap varG . instrG $ "alloca " <> ty'
--     voidG $ "store " <> ty' <> " " <> e1' <> ", " <> pp (Prim (Ptr ty)) <> " " <> p
--     voidG $ varG x <> " = load " <> ty' <> ", " <> pp (Prim (Ptr ty)) <> " " <> p
--     expG e
--   ACall (π -> ty :: Ty) e es -> do
--     e' <- expG e
--     es' <- mapM (fmap varG . expG) es
--     (e' ∈) <$> ask >>= \case
--       True -> voidG $ "br label " <> varG e'
--       False -> instrG $ "call " <> pp ty <> " " <> varG e' <> "(" <> commaSep es' <> ")"
--   AGep _ e p -> undefined -- TODO
--   ALoad (π -> ty :: Ty) e -> do
--     let ty' = pp ty
--     e' <- varG <$> expG e
--     instrG $ "load " <> ty' <> ", " <> ty' <> " " <> e'
--   AStore _ d s@(Anno (π -> ts :: Ty)) e -> do
--     d' <- varG <$> expG d
--     s' <- varG <$> expG s
--     voidG $ "store " <> pp ts <> " " <> s' <> ", " <> pp (Prim (Ptr ts)) <> " " <> d'
--     expG e
--   ARec _ fs e -> undefined -- TODO
--   ACase _ e d pes -> undefined -- TODO
-- 
-- -- genTop :: AnnProcess -> Gen Doc
-- -- genTop (FV vs p) = do
-- --   tell $ line "#include <stdlib.h>"
-- --   tell $ line "#include \"runtime.c\""
-- --   mainG <$> expG (ABoth (vs, Any False) (AHalt (S.empty, Any False)) p)
-- -- 
-- -- runGen :: Alloc -> Gen Doc -> String
-- -- runGen alloc m =
-- --   let (main, helpers) = runWriter $ m `runReaderT` alloc `evalStateT` 0 in
-- --   runDoc alloc (helpers <> main)
-- -- 
-- -- -- -------------------- AST Compilation --------------------
-- -- 
-- -- codeGen' :: Bool -> Process -> IO String
-- -- codeGen' sinking p = do
-- --   let p' = (if sinking then sinkNews else id) . fvAnno $ ub p
-- --   a <- alloc p'
-- --   return $ runGen a (genTop p')
-- -- 
-- -- codeGen :: Process -> IO String
-- -- codeGen = codeGen' True
-- -- 
-- -------------------- Parsing utils --------------------

newtype PError = PError String deriving (Eq, Ord)

type Parser = ParsecT PError String (State (Map String Word))

instance P.ShowErrorComponent PError where showErrorComponent (PError s) = s

sc :: Parser ()
sc = L.space space1 empty empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: String -> Parser String
symbol = L.symbol sc

tryAll :: (Foldable f, MonadParsec e s m) => f (m a) -> m a
tryAll = foldr ((<|>) . P.try) empty

symbols :: [String] -> Parser String
symbols = tryAll . fmap symbol

parens :: Parser a -> Parser a
parens = P.between (symbol "(") (symbol ")")

braces :: Parser a -> Parser a
braces = P.between (symbol "{") (symbol "}")

brackets :: Parser a -> Parser a
brackets = P.between (symbol "[") (symbol "]")

angles :: Parser a -> Parser a
angles = P.between (symbol "<") (symbol ">")

tupleOf :: Parser a -> Parser [a]
tupleOf p = parens (p `P.sepBy` symbol ",")

-- -------------------- Parsing --------------------

keywords :: [String]
keywords = ["rec", "and", "in", "case", "as"]

word :: Parser String
word = do
  s <- lexeme $ some (alphaNumChar <|> char '_')
  guard . not $ s `elem` keywords
  return s

varP' :: Bool -> Parser Var
varP' strict = do
  x <- word
  (M.!? x) <$> get >>= \case
    Nothing | strict ->
      P.customFailure . PError $ "Variable not in scope: " ++ x
    Nothing -> do
      n <- fromIntegral . M.size <$> get
      modify' (M.insert x n)
      return n
    Just n -> return n

varP :: Parser Var = varP' True

bindP :: Parser Var = varP' False

wordP :: Parser Word = read <$> lexeme (P.takeWhile1P (Just "digit") isDigit)

intP :: Parser Integer
intP = read <$> lexeme ((++) <$> tryAll ["-", ""] <*> P.takeWhile1P (Just "digit") isDigit)

ptyP :: Parser PTy
ptyP = tryAll
  [ "i" >> I <$> wordP
  , symbol "half" $> Half
  , symbol "float" $> Float
  , symbol "double" $> Double
  , symbol "fp128" $> FP128
  , parens ptyP
  , symbol "&" >> Ptr <$> tyP
  ]

tyP :: Parser Ty
tyP = tryAll
  [ symbol "void" $> Void
  , angles $ Vec <$> wordP <* symbol "x" <*> ptyP
  , brackets $ Arr <$> wordP <* symbol "x" <*> tyP
  , braces $ Tup <$> P.many tyP
  , symbol "fun" >> FPtr <$> tupleOf tyP <* symbol "->" <*> tyP
  , PTy <$> ptyP
  , parens tyP
  ]

widthP :: Parser Width = wordP

primP :: Parser Prim
primP = tryAll
  [ symbol "add" $> Add
  , symbol "mul" $> Mul
  , symbol "sub" $> Sub
  , symbol "div" $> Div
  ]

locP :: Parser ParseAnn = (\ pos -> loc .==. pos .*. emptyRecord) <$> P.getSourcePos

funcP :: Parser (Func ParseAnn)
funcP =
  Func
    <$> locP <*> bindP <*> tupleOf argP <* symbol ":" <*> tyP <* symbol "="
    <*> expP
  where
    argP = (,,) <$> locP <*> bindP <* symbol ":" <*> tyP

armP :: Parser (Arm ParseAnn)
armP = (:=>) <$> (tryAll [Just <$> intP, symbol "_" $> Nothing]) <* symbol "=>" <*> expP

expP :: Parser (Exp ParseAnn)
expP = do
  loc <- locP
  e <- tryAll
    [ Var loc <$> varP
    , Int loc <$> intP <* symbol "i" <*> widthP
    , Prim loc <$> primP <*> tupleOf expP
    , symbol "let" >> Let loc
        <$> bindP <* symbol ":" <*> tyP <* symbol "="
        <*> expP <* symbol "in" <*> expP
    , symbol "case" >> Case loc <$> expP <*> braces (armP `P.sepBy` symbol ",")
    , symbol "rec" >> Rec loc <$> (funcP `P.sepBy` symbol "and") <* symbol "in" <*> expP
    , parens expP
    ]
  tryAll
    [ symbol ":" >> Ann loc e <$> tyP
    , symbol "as" >> Coerce loc e <$> tyP
    , Call loc e <$> tupleOf expP
    , pure e
    ]

parse' :: String -> String -> Either String (Exp ParseAnn)
parse' fname s =
  first P.errorBundlePretty
    $ P.runParserT (expP <* P.eof) fname s `evalState` M.empty

parse :: String -> Either String (Exp ParseAnn) = parse' ""

parseFile :: FilePath -> IO (Either String (Exp ParseAnn))
parseFile f = parse' f <$> readFile f

-- -- -- -------------------- Compilation to C --------------------
-- -- 
-- -- transpile :: String -> IO (Either String String)
-- -- transpile s = mapM codeGen (parse s)
-- -- 
-- -- transpileFile :: FilePath -> IO (Either String String)
-- -- transpileFile f = parseFile f >>= \case
-- --   Left err -> return $ Left err
-- --   Right p -> Right <$> codeGen p
-- -- 
-- -- -- -------------------- Full compilation --------------------
-- -- 
-- -- compile :: String -> FilePath -> FilePath -> IO ()
-- -- compile s cOut binOut = transpile s >>= \case
-- --   Left err -> putStrLn err
-- --   Right c -> do
-- --     writeFile cOut c
-- --     let flags = ["-O2", "-g", "-I", "runtime", "runtime/gt_switch.s", cOut, "-o", binOut]
-- --     P.createProcess (P.proc "gcc" flags)
-- --     return ()
-- -- 
-- -- compileFile :: FilePath -> FilePath -> FilePath -> IO ()
-- -- compileFile piIn cOut binOut = do
-- --   s <- readFile piIn
-- --   compile s cOut binOut
