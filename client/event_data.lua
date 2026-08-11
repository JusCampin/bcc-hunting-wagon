-- Minimal local buffer reader for GET_EVENT_DATA. The buffer must be larger
-- than LUA_MAXSHORTLEN so Lua does not intern it and the native can write to it.
local createBlob = string.blob or function(length)
    return string.rep('\0', math.max(41, length))
end

EventDataView = {}
EventDataView.__index = EventDataView

function EventDataView.New(length)
    return setmetatable({ blob = createBlob(length) }, EventDataView)
end

function EventDataView:Buffer()
    return self.blob
end

function EventDataView:GetInt32(offset)
    return string.unpack('<i4', self.blob, offset + 1)
end
