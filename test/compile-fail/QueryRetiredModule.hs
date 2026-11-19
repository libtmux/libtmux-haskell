module QueryRetiredModule where
import LibTmux qualified as Tmux
import LibTmux.Query qualified as Q
import LibTmux.Query.Pane qualified as Pane
retired :: Q.Field Tmux.Pane Bool
retired = Pane.active
