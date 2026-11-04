local mp = require 'mp'

-- Older distro packages lack these options; setting them then returns an ignored error.
mp.set_property_native('options/save-watch-history', false)
mp.set_property('options/watch-history-path', '/dev/null')
