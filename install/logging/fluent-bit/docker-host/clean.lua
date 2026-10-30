-- Strips ANSI colour codes and the trailing newline Docker keeps on every line.
function clean(tag, timestamp, record)
    local log = record["log"]
    if type(log) ~= "string" then
        return 0, timestamp, record
    end
    log = log:gsub("\27%[[%d;]*m", ""):gsub("[\r\n]+$", "")
    record["log"] = log
    return 2, timestamp, record
end
