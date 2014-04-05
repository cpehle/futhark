module L0C.EnablingOpts.ScalExp
  ( RelOp0(..)
  , ScalExp(..)
  , ppScalExp
  , toScalExp
  , LookupVar
  , fromScalExp
  , getIds
  )
where

import Control.Applicative
import Control.Monad
import Data.List
import Data.Loc

import Text.PrettyPrint.Mainland

import L0C.InternalRep
import L0C.MonadFreshNames
import L0C.Tools

-----------------------------------------------------------------
-- BINARY OPERATORS for Numbers                                --
-- Note that MOD, BAND, XOR, BOR, SHIFTR, SHIFTL not supported --
--   `a SHIFTL/SHIFTR p' can be translated if desired as as    --
--   `a * 2^p' or `a / 2^p                                     --
-----------------------------------------------------------------

-- | Relational operators.
data RelOp0 = LTH0
            | LEQ0
         -- | EQL0
             deriving (Eq, Ord, Enum, Bounded, Show)

-- | Representation of a scalar expression, which is:
--
--    (i) an algebraic expression, e.g., min(a+b, a*b),
--
--   (ii) a relational expression: a+b < 5,
--
--  (iii) a logical expression: e1 and (not (a+b>5)
data ScalExp= Val     BasicValue
            | Id      Ident
            | SNeg    ScalExp
            | SNot    ScalExp
            | SPlus   ScalExp ScalExp
            | SMinus  ScalExp ScalExp
            | STimes  ScalExp ScalExp
            | SPow    ScalExp ScalExp
            | SDivide ScalExp ScalExp
            | MaxMin  Bool   [ScalExp]
            | RelExp  RelOp0  ScalExp
            | SLogAnd ScalExp ScalExp
            | SLogOr  ScalExp ScalExp
              deriving (Eq, Ord, Show)

instance Pretty ScalExp where
  pprPrec _ (Val val) = ppr $ BasicVal val
  pprPrec _ (Id v) = ppr v
  pprPrec _ (SNeg e) = text "-" <> pprPrec 9 e
  pprPrec _ (SNot e) = text "-" <> pprPrec 9 e
  pprPrec prec (SPlus x y) = ppBinOp prec "+" 4 4 x y
  pprPrec prec (SMinus x y) = ppBinOp prec "-" 4 10 x y
  pprPrec prec (SPow x y) = ppBinOp prec "^" 6 6 x y
  pprPrec prec (STimes x y) = ppBinOp prec "*" 5 5 x y
  pprPrec prec (SDivide x y) = ppBinOp prec "/" 5 10 x y
  pprPrec prec (SLogOr x y) = ppBinOp prec "||" 0 0 x y
  pprPrec prec (SLogAnd x y) = ppBinOp prec "&&" 1 1 x y
  pprPrec prec (RelExp LTH0 e) = ppBinOp prec "<" 2 2 e (Val $ IntVal 0)
  pprPrec prec (RelExp LEQ0 e) = ppBinOp prec "<=" 2 2 e (Val $ IntVal 0)
  pprPrec _ (MaxMin True es) = text "max" <> parens (commasep $ map ppr es)
  pprPrec _ (MaxMin False es) = text "min" <> parens (commasep $ map ppr es)

ppBinOp :: Int -> String -> Int -> Int -> ScalExp -> ScalExp -> Doc
ppBinOp p bop precedence rprecedence x y =
  parensIf (p > precedence) $
           pprPrec precedence x <+/>
           text bop <+>
           pprPrec rprecedence y

ppScalExp :: ScalExp -> String
ppScalExp = pretty 80 . ppr

-- | A function that checks whether a variable name corresponds to a
-- scalar expression.
type LookupVar = VName -> Maybe ScalExp

toScalExp :: LookupVar -> Exp -> Maybe ScalExp
toScalExp look (SubExps [se] _)    =
  toScalExp' look se
toScalExp look (BinOp Less x y _ _) =
  RelExp LTH0 <$> (SMinus <$> toScalExp' look x <*> toScalExp' look y)
toScalExp look (BinOp Leq x y _ _) =
  RelExp LEQ0 <$> (SMinus <$> toScalExp' look x <*> toScalExp' look y)
toScalExp look (BinOp bop x y (Basic t) _)
  | t `elem` [Int, Bool] = -- XXX: Only integers and booleans, OK?
  binOpScalExp bop <*> toScalExp' look x <*> toScalExp' look y

toScalExp _ _ = Nothing

binOpScalExp :: BinOp -> Maybe (ScalExp -> ScalExp -> ScalExp)
binOpScalExp bop = liftM snd $ find ((==bop) . fst)
                   [ (Plus, SPlus)
                   , (Minus, SMinus)
                   , (Times, STimes)
                   , (Divide, SDivide)
                   , (Pow, SPow)
                   , (LogAnd, SLogAnd)
                   , (LogOr, SLogOr)
                   ]

toScalExp' :: LookupVar -> SubExp -> Maybe ScalExp
toScalExp' look (Var v) =
  look (identName v) <|> Just (Id v)
toScalExp' _ (Constant (BasicVal val) _) =
  Just $ Val val
toScalExp' _ _ = Nothing

-- XXX: We assume a numeric result is always an integer.  Is this
-- kosher?
fromScalExp :: MonadFreshNames m => SrcLoc -> ScalExp -> m (Exp, [Binding])
fromScalExp loc = runBinder'' . convert
  where convert :: ScalExp -> Binder Exp
        convert (Val val) = return $ subExp $ Constant (BasicVal val) loc
        convert (Id v)    = return $ subExp $ Var v
        convert (SNeg se) = eNegate (convert se) loc
        convert (SNot se) = eNot (convert se) loc
        convert (SPlus x y) = eBinOp Plus (convert x) (convert y) (Basic Int) loc
        convert (SMinus x y) = eBinOp Minus (convert x) (convert y) (Basic Int) loc
        convert (STimes x y) = eBinOp Times (convert x) (convert y) (Basic Int) loc
        convert (SDivide x y) = eBinOp Divide (convert x) (convert y) (Basic Int) loc
        convert (SPow x y) = eBinOp Pow (convert x) (convert y) (Basic Int) loc
        convert (SLogAnd x y) = eBinOp LogAnd (convert x) (convert y) (Basic Bool) loc
        convert (SLogOr x y) = eBinOp LogOr (convert x) (convert y) (Basic Bool) loc
        convert (RelExp LTH0 x) = eBinOp Less (convert x) (pure zero) (Basic Bool) loc
        convert (RelExp LEQ0 x) = eBinOp Leq (convert x) (pure zero) (Basic Bool) loc
        convert (MaxMin _ []) = fail "ScalExp.fromScalExp: MaxMin empty list"
        convert (MaxMin maxOrMin (e:es)) = do
          e'  <- convert e
          es' <- mapM convert es
          foldM (select maxOrMin) e' es'

        select :: Bool -> Exp -> Exp -> Binder Exp
        select getMax cur next =
          let t = if typeOf cur == [Basic Int]
                  then Basic Int
                  else Basic Bool
              cmp = eBinOp Less (pure cur) (pure next) t loc
              (pick, discard)
                | getMax    = (next, cur)
                | otherwise = (cur, next)
          in eIf cmp (eBody $ pure pick) (eBody $ pure discard) [t] loc

        zero = subExp $ Constant (BasicVal $ IntVal 0) loc

------------------------
--- Helper Functions ---
------------------------
getIds :: ScalExp -> [Ident]
getIds (Val   _) = []
getIds (Id    i) = [i]
getIds (SNeg  e) = getIds e
getIds (SNot  e) = getIds e
getIds (SPlus x y)   = foldl (\l e->l++(getIds e)) [] [x,y]
getIds (SMinus x y)  = foldl (\l e->l++(getIds e)) [] [x,y]
getIds (SPow x y)    = foldl (\l e->l++(getIds e)) [] [x,y]
getIds (STimes x y)  = foldl (\l e->l++(getIds e)) [] [x,y]
getIds (SDivide x y) = foldl (\l e->l++(getIds e)) [] [x,y]
getIds (SLogOr x y)  = foldl (\l e->l++(getIds e)) [] [x,y]
getIds (SLogAnd x y) = foldl (\l e->l++(getIds e)) [] [x,y]
getIds (RelExp LTH0 e) = getIds e
getIds (RelExp LEQ0 e) = getIds e
getIds (MaxMin True  es) = foldl (\l e->l++(getIds e)) [] es
getIds (MaxMin False es) = foldl (\l e->l++(getIds e)) [] es
