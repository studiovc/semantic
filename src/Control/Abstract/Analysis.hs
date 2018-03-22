{-# LANGUAGE DataKinds, MultiParamTypeClasses, ScopedTypeVariables, TypeFamilies #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-} -- For runAnalysis
module Control.Abstract.Analysis
( MonadAnalysis(..)
, evaluateTerm
, evaluateModule
, withModules
, evaluateModules
, require
, load
, liftAnalyze
, runAnalysis
, module X
, Subterm(..)
, SubtermAlgebra
) where

import Control.Abstract.Evaluator as X
import Control.Effect as X
import Control.Effect.Fresh as X
import Control.Effect.NonDet as X
import qualified Control.Monad.Effect as Effect
import Control.Monad.Effect.Fail as X
import Control.Monad.Effect.Reader as X
import Control.Monad.Effect.Resumable
import Control.Monad.Effect.State as X
import Data.Abstract.Environment (Environment)
import qualified Data.Abstract.Environment as Env
import Data.Abstract.Exports (Exports)
import qualified Data.Abstract.Exports as Export
import Data.Abstract.Module
import Data.Abstract.ModuleTable as ModuleTable
import Data.Abstract.Value
import Data.Coerce
import Prelude hiding (fail)
import Prologue

-- | A 'Monad' in which one can evaluate some specific term type to some specific value type.
--
--   This typeclass is left intentionally unconstrained to avoid circular dependencies between it and other typeclasses.
class (MonadEvaluator term value m, Recursive term) => MonadAnalysis term value m where
  -- | The effects necessary to run the analysis. Analyses which are composed on top of (wrap) other analyses should include the inner analyses 'RequiredEffects' in their own list.
  type family RequiredEffects term value m :: [* -> *]

  -- | Analyze a term using the semantics of the current analysis. This should generally only be called by 'evaluateTerm' and by definitions of 'analyzeTerm' in instances for composite analyses.
  analyzeTerm :: SubtermAlgebra (Base term) term (m value)

  -- | Analyze a module using the semantics of the current analysis. This should generally only be called by 'evaluateModule' and by definitions of 'analyzeModule' in instances for composite analyses.
  analyzeModule :: SubtermAlgebra Module term (m value)

  -- | Isolate the given action with an empty global environment and exports.
  isolate :: m a -> m a
  isolate = withEnv mempty . withExports mempty

-- | Evaluate a term to a value using the semantics of the current analysis.
--
--   This should always be called when e.g. evaluating the bodies of closures instead of explicitly folding either 'eval' or 'analyzeTerm' over subterms, except in 'MonadAnalysis' instances themselves. On the other hand, top-level evaluation should be performed using 'evaluateModule'.
evaluateTerm :: MonadAnalysis term value m => term -> m value
evaluateTerm = foldSubterms analyzeTerm

-- | Evaluate a (root-level) term to a value using the semantics of the current analysis. This should be used to evaluate single-term programs as well as each module in multi-term programs.
evaluateModule :: forall m term value effects
               .  ( Effectful m
                  , Member (Resumable (EvaluateModule term) value) effects
                  , MonadAnalysis term value (m effects)
                  )
               => Module term
               -> m effects value
evaluateModule m = resumeException (evaluateM m)
  (\ yield (EvaluateModule m) -> evaluateM m >>= yield)
  where evaluateM :: Module term -> m effects value
        evaluateM = analyzeModule . fmap (Subterm <*> evaluateTerm)


-- | Run an action with the a list of 'Module's available for imports.
withModules :: ( Effectful m
               , Member (Resumable (EvaluateModule term) value) effects
               , MonadAnalysis term value (m effects)
               )
               => [Module term]
               -> m effects a
               -> m effects a
withModules = localModuleTable . const . ModuleTable.fromList

-- | Evaluate with a list of modules in scope, taking the head module as the entry point.
evaluateModules :: ( Effectful m
                   , Member (Resumable (EvaluateModule term) value) effects
                   , MonadAnalysis term value (m effects)
                   )
                => [Module term]
                -> m effects value
evaluateModules [] = fail "evaluateModules: empty list"
evaluateModules (m:ms) = withModules ms (evaluateModule m)


-- | Require/import another term/file and return an Effect.
--
-- Looks up the term's name in the cache of evaluated modules first, returns a value if found, otherwise loads/evaluates the module.
require :: ( MonadAnalysis term value m
           , MonadThrow (EvaluateModule term) value m
           , Ord (LocationFor value)
           )
        => ModuleName
        -> m (EnvironmentFor value)
require name = getModuleTable >>= maybe (load name) pure . moduleTableLookup name

-- | Load another term/file and return an Effect.
--
-- Always loads/evaluates.
load :: ( MonadAnalysis term value m
        , MonadThrow (EvaluateModule term) value m
        , Ord (LocationFor value)
        )
     => ModuleName
     -> m (EnvironmentFor value)
load name = askModuleTable >>= maybe notFound evalAndCache . moduleTableLookup name
  where
    notFound = fail ("cannot load module: " <> show name)
    evalAndCache :: forall term value m . (MonadAnalysis term value m, MonadThrow (EvaluateModule term) value m, Ord (LocationFor value)) => [Module term] -> m (EnvironmentFor value)
    evalAndCache []     = pure mempty
    evalAndCache (x:xs) = do
      void (throwException (EvaluateModule x) :: m value)
      env <- filterEnv <$> getExports <*> getEnv
      modifyModuleTable (moduleTableInsert name env)
      (env <>) <$> evalAndCache xs

    -- TODO: If the set of exports is empty because no exports have been
    -- defined, do we export all terms, or no terms? This behavior varies across
    -- languages. We need better semantics rather than doing it ad-hoc.
    filterEnv :: (Ord l) => Exports l a -> Environment l a -> Environment l a
    filterEnv ports env
      | Export.null ports = env
      | otherwise = Export.toEnvironment ports <> Env.overwrite (Export.aliases ports) env

-- | Lift a 'SubtermAlgebra' for an underlying analysis into a containing analysis. Use this when defining an analysis which can be composed onto other analyses to ensure that a call to 'analyzeTerm' occurs in the inner analysis and not the outer one.
liftAnalyze :: ( Coercible (  m term value (effects :: [* -> *]) value) (t m term value effects value)
               , Coercible (t m term value effects value) (  m term value effects value)
               , Functor base
               )
            => SubtermAlgebra base term (  m term value effects value)
            -> SubtermAlgebra base term (t m term value effects value)
liftAnalyze analyze term = coerce (analyze (second coerce <$> term))


-- | Run an analysis, performing its effects and returning the result alongside any state.
--
--   This enables us to refer to the analysis type as e.g. @Analysis1 (Analysis2 Evaluating) Term Value@ without explicitly mentioning its effects (which are inferred to be simply its 'RequiredEffects').
runAnalysis :: ( Effectful m
               , RunEffects effects a
               , RequiredEffects term value (m effects) ~ effects
               , MonadAnalysis term value (m effects)
               )
            => m effects a
            -> Final effects a
runAnalysis = Effect.run . runEffects . lower
