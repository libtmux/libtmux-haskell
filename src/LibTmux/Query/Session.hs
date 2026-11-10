-- | Session fields and contextual children for "LibTmux.Query".
--
-- All tokens describe the tmux 3.3a baseline. 'windowLinks' preserves each
-- observed index, including several links to one physical window. 'clients'
-- describes captured attachments and may be a known empty relationship.
module LibTmux.Query.Session (id, name, attached, windowLinks, clients) where

import Prelude hiding (id)
import Data.Text (Text)
import LibTmux.Id (SessionId)
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (Field, ToMany)
import LibTmux.Snapshot (Session, WindowLink, Client)

-- | Native session ID without a connection-generation guarantee.
id :: Field Session SessionId
id = F.SessionId

-- | Captured UTF-8 session name. Equality does not normalize Unicode.
name :: Field Session Text
name = F.SessionName

-- | Nonnegative count of attached clients as observed by tmux.
attached :: Field Session Integer
attached = F.SessionAttached

-- | Every window link owned by this session, retaining index and multiplicity.
windowLinks :: ToMany Session WindowLink
windowLinks = Q.SessionLinks

-- | Captured clients attached to this session; an empty list is known absence.
clients :: ToMany Session Client
clients = Q.SessionClients
