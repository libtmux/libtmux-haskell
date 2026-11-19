module QueryFieldConstructor where
import LibTmux qualified as Tmux
import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F
forged :: Q.Field Tmux.Pane Bool
forged = F.PaneActive
