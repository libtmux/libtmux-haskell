-- | Parse a tmuxp document, inspect the plan, then apply it to a new session
-- through an owned or borrowed Server. Planning reads no files or environment.
module LibTmux.Workspace
  ( PlanInputs (..), defaultPlanInputs
  , WorkspacePlan, WorkspacePreview (..), WindowPlan (..), PanePlan (..), WorkspaceCommand (..)
  , WorkspaceError (..), YamlError (..)
  , planTmuxp, previewWorkspace
  , applyWorkspace, WorkspaceApplyError (..)
  , WorkspaceRecovery, workspaceRecoveries, workspaceRecoverySession, pendingWorkspaceCreation
  ) where

import LibTmux.Workspace.Apply
import LibTmux.Workspace.Plan
import LibTmux.Workspace.Yaml (YamlError (..))

-- | Inspect resolved windows, panes and inherited settings without applying them.
previewWorkspace :: WorkspacePlan -> WorkspacePreview
previewWorkspace (WorkspacePlan preview) = preview
