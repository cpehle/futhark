module Futhark.Optimise.InPlaceLowering.LowerIntoBinding
       (
         lowerUpdate
       , DesiredUpdate (..)
       ) where

import Control.Applicative
import Control.Monad
import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.Either

import Futhark.Representation.AST
import Futhark.Tools
import Futhark.MonadFreshNames
import Futhark.Optimise.InPlaceLowering.SubstituteIndices

data DesiredUpdate =
  DesiredUpdate { updateBindee :: Ident
                , updateCertificates :: Certificates
                , updateSource :: Ident
                , updateIndices :: [SubExp]
                , updateValue :: Ident
                }

updateHasValue :: VName -> DesiredUpdate -> Bool
updateHasValue name = (name==) . identName . updateValue

lowerUpdate :: (Bindable lore, MonadFreshNames m) =>
               Binding lore -> [DesiredUpdate] -> Maybe (m [Binding lore])
lowerUpdate (Let pat _ (LoopOp (DoLoop res merge i bound body))) updates = do
  canDo <- lowerUpdateIntoLoop updates pat res merge body
  Just $ do
    (prebnds, pat', res', merge', body') <- canDo
    return $ prebnds ++ [mkLet' pat' $ LoopOp $ DoLoop res' merge' i bound body']
lowerUpdate
  (Let pat _ (PrimOp (SubExp (Var v))))
  [DesiredUpdate bindee cs src is val]
  | patternIdents pat == [src] =
    Just $ return [mkLet [(bindee,BindInPlace cs v is)] $
                   PrimOp $ SubExp $ Var val]
lowerUpdate
  (Let (Pattern [PatElem v BindVar _]) _ e)
  [DesiredUpdate bindee cs src is val]
  | v == val =
    Just $ return [mkLet [(bindee,BindInPlace cs src is)] e,
                   mkLet' [v] $ PrimOp $ Index cs bindee is]
lowerUpdate _ _ =
  Nothing

lowerUpdateIntoLoop :: (Bindable lore, MonadFreshNames m) =>
                       [DesiredUpdate]
                    -> Pattern lore
                    -> [Ident]
                    -> [(FParam lore, SubExp)]
                    -> Body lore
                    -> Maybe (m ([Binding lore],
                                 [Ident],
                                 [Ident],
                                 [(FParam lore, SubExp)],
                                 Body lore))
lowerUpdateIntoLoop updates pat res merge body = do
  -- Algorithm:
  --
  --   0) Map each result of the loop body to a corresponding in-place
  --      update, if one exists.
  --
  --   1) Create new merge variables corresponding to the arrays being
  --      updated; extend the pattern and the @res@ list with these,
  --      and remove the parts of the result list that have a
  --      corresponding in-place update.
  --
  --      (The creation of the new merge variable identifiers is
  --      actually done at the same time as step (0)).
  --
  --   2) Create in-place updates at the end of the loop body.
  --
  --   3) Create index expressions that read back the values written
  --      in (2).  If the merge parameter corresponding to this value
  --      is unique, also @copy@ this value.
  --
  --   4) Update the result of the loop body to properly pass the new
  --      arrays and indexed elements to the next iteration of the
  --      loop.
  --
  -- We also check that the merge parameters we work with have
  -- loop-invariant shapes.
  mk_in_place_map <- summariseLoop updates resmap merge
  Just $ do
    in_place_map <- mk_in_place_map
    (merge',prebnds) <- mkMerges in_place_map
    let (pat',res') = mkResAndPat in_place_map
        idxsubsts = indexSubstitutions in_place_map
    (idxsubsts', newbnds) <- substituteIndices idxsubsts $ bodyBindings body
    let body' = mkBody newbnds $ manipulateResult in_place_map idxsubsts'
    return (prebnds, pat', res', merge', body')
  where mergeparams = map fst merge
        resmap = loopResultValues
                 (patternIdents pat) (map identName res)
                 (map fparamName mergeparams) $
                 resultSubExps $ bodyResult body

        mkMerges :: (MonadFreshNames m, Bindable lore) =>
                    [LoopResultSummary]
                 -> m ([(FParamT (), SubExp)], [Binding lore])
        mkMerges summaries = do
          ((origmerge, extramerge), prebnds) <-
            runBinderT $ partitionEithers <$> mapM mkMerge summaries
          return (origmerge ++ extramerge, prebnds)

        mkMerge summary
          | Just (update, mergeident) <- relatedUpdate summary = do
            source <- letInPlace "modified_source"
                      (updateCertificates update)
                      (updateSource update)
                      (updateIndices update)
                      $ PrimOp $ SubExp $ snd $ mergeParam summary
            return $ Right (FParam mergeident (), Var source)
          | otherwise = return $ Left $ mergeParam summary

        mkResAndPat summaries =
          let (orig,extra) = partitionEithers $ mapMaybe mkResAndPat' summaries
              (origpat, origres) = unzip orig
              (extrapat, extrares) = unzip extra
          in (origpat ++ extrapat, origres ++ extrares)

        mkResAndPat' summary
          | Just (update, mergeident) <- relatedUpdate summary =
              Just $ Right (updateBindee update, mergeident)
          | Just v <- inPatternAs summary =
              Just $ Left (v, fparamIdent $ fst $ mergeParam summary)
          | otherwise =
              Nothing

summariseLoop :: MonadFreshNames m =>
                 [DesiredUpdate]
              -> [(SubExp, Maybe Ident)]
              -> [(FParamT (), SubExp)]
              -> Maybe (m [LoopResultSummary])
summariseLoop updates resmap merge =
  sequence <$> zipWithM summariseLoopResult resmap merge
  where summariseLoopResult (se, Just v) (fparam, mergeinit)
          | Just update <- find (updateHasValue $ identName v) updates =
            if hasLoopInvariantShape fparam then Just $ do
              ident <-
                newIdent "lowered_array" $ identType $ updateBindee update
              return LoopResultSummary { resultSubExp = se
                                       , inPatternAs = Just v
                                       , mergeParam = (fparam, mergeinit)
                                       , relatedUpdate = Just (update, ident)
                                       }
            else Nothing
        summariseLoopResult (se, patpart) (fparam, mergeinit) =
          Just $ return LoopResultSummary { resultSubExp = se
                                          , inPatternAs = patpart
                                          , mergeParam = (fparam, mergeinit)
                                          , relatedUpdate = Nothing
                                          }

        hasLoopInvariantShape = all loopInvariant . arrayDims . fparamType

        merge_param_names = map (fparamName . fst) merge

        loopInvariant (Var v)       = identName v `notElem` merge_param_names
        loopInvariant (Constant {}) = True

data LoopResultSummary =
  LoopResultSummary { resultSubExp :: SubExp
                    , inPatternAs :: Maybe Ident
                    , mergeParam :: (FParamT (), SubExp)
                    , relatedUpdate :: Maybe (DesiredUpdate, Ident)
                    }

indexSubstitutions :: [LoopResultSummary]
                   -> IndexSubstitutions
indexSubstitutions = mapMaybe getSubstitution
  where getSubstitution res = do
          (DesiredUpdate _ cs _ is _, mergeident) <- relatedUpdate res
          let name = fparamName $ fst $ mergeParam res
          return (name, (cs, mergeident, is))

manipulateResult :: [LoopResultSummary]
                 -> [IndexSubstitution]
                 -> Result
manipulateResult summaries substs =
  let orig_ses = mapMaybe unchangedRes summaries
      subst_ses = map (\(_,v,_) -> Var v) substs
  in Result $ orig_ses ++ subst_ses
  where
    unchangedRes summary =
      case relatedUpdate summary of
        Nothing -> Just $ resultSubExp summary
        Just _  -> Nothing
