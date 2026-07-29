--!nonstrict

local assignments = {}
local runtime = {}
local generations = {}

local function copyTable(value)
    local result = {}
    for key, item in pairs(value or {}) do
        result[key] = item
    end
    return result
end

local function copyList(values)
    local result = {}
    for index, value in ipairs(values or {}) do
        result[index] = value
    end
    return result
end

local function targetsFor(target, connectors)
    if target ~= "*" then
        return { target }
    end

    local targets = copyList(connectors)
    table.sort(targets)
    return targets
end

local function detectedConnectors()
    local connectors = {}
    for _, output in ipairs(noctalia.outputs()) do
        if type(output.name) == "string" and output.name ~= "" then
            table.insert(connectors, output.name)
        end
    end
    table.sort(connectors)
    return connectors
end

local function nextGeneration(connector, store)
    store = store or generations
    store[connector] = (store[connector] or 0) + 1
    return store[connector]
end

local function isCurrent(connector, generation, store)
    store = store or generations
    return store[connector] == generation
end

local function generationGuardedSet(store, generationStore, connector, generation, value)
    if not isCurrent(connector, generation, generationStore) then
        return false
    end
    store[connector] = value
    return true
end

local function connectorSet(connectors)
    local result = {}
    for _, connector in ipairs(connectors) do
        result[connector] = true
    end
    return result
end

local function reconcileOutputs(previousConnectors, currentConnectors, durable, live)
    local previous = connectorSet(previousConnectors)
    local current = connectorSet(currentConnectors)
    local stops = {}
    local restores = {}

    for connector in pairs(previous) do
        if not current[connector] then
            live[connector] = nil
            table.insert(stops, connector)
        end
    end

    for connector in pairs(current) do
        local assignment = durable[connector]
        if not previous[connector] and assignment and assignment.kind == "video" then
            table.insert(restores, connector)
        end
    end

    table.sort(stops)
    table.sort(restores)
    return stops, restores
end

local function applyAssignmentBatch(target, connectors, assignment, durable, apply)
    local results = {}
    for _, connector in ipairs(targetsFor(target, connectors)) do
        local ok, message = apply(connector, assignment)
        results[connector] = { ok = ok, error = ok and nil or message }
        if ok then
            durable[connector] = copyTable(assignment)
        end
    end
    return results
end

local function validAbsolutePath(path)
    return type(path) == "string" and path:sub(1, 1) == "/" and path ~= "/"
end

local function validateAssignment(connector, record)
    if type(connector) ~= "string" or connector == "" or type(record) ~= "table" then
        return nil
    end
    if record.kind ~= "image" and record.kind ~= "video" then
        return nil
    end
    if not validAbsolutePath(record.path) then
        return nil
    end
    if record.desired_playback ~= "playing" and record.desired_playback ~= "paused" then
        return nil
    end
    if record.preview_path ~= nil and not validAbsolutePath(record.preview_path) then
        return nil
    end

    return {
        kind = record.kind,
        path = record.path,
        preview_path = record.preview_path,
        desired_playback = record.desired_playback,
    }
end

local function assignmentsPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    return directory .. "/assignments.json"
end

local function loadAssignments()
    local path = assignmentsPath()
    if not path then
        return {}
    end

    local contents = noctalia.readFile(path)
    if not contents then
        return {}
    end

    local decoded, decodeError = noctalia.json.decode(contents)
    if type(decoded) ~= "table" or type(decoded.assignments) ~= "table" then
        noctalia.log("warn", "Ignoring invalid assignments file: " .. tostring(decodeError or "invalid shape"))
        return {}
    end

    local loaded = {}
    for connector, record in pairs(decoded.assignments) do
        local valid = validateAssignment(connector, record)
        if valid then
            loaded[connector] = valid
        end
    end
    return loaded
end

local function saveAssignments()
    local path = assignmentsPath()
    if not path then
        return false, "plugin data directory is unavailable"
    end

    -- ponytail: assignments are rewritten as one small JSON object; split storage
    -- only if real configurations make write size measurable.
    local encoded, encodeError = noctalia.json.encode({ version = 1, assignments = assignments }, true)
    if not encoded then
        return false, encodeError or "could not encode assignments"
    end

    local temporaryPath = path .. ".tmp"
    local written, writeError = noctalia.writeFile(temporaryPath, encoded)
    if not written then
        return false, writeError or "could not write assignments"
    end

    local renamed, renameError = noctalia.renameFile(temporaryPath, path)
    if not renamed then
        noctalia.removeFile(temporaryPath)
        return false, renameError or "could not replace assignments"
    end
    return true
end

local function runModelChecks()
    local connectors = { "eDP-1", "DP-1", "DP-3" }

    local durable = {
        ["eDP-1"] = { kind = "image", path = "/wallpapers/still.jpg", desired_playback = "playing" },
        ["DP-1"] = { kind = "video", path = "/wallpapers/motion.mp4", desired_playback = "paused" },
    }
    assert(durable["eDP-1"].path ~= durable["DP-1"].path, "outputs lost independent assignments")

    local targets = targetsFor("*", connectors)
    assert(table.concat(targets, ",") == "DP-1,DP-3,eDP-1", "All target was not sorted")

    local testGenerations = {}
    local testRuntime = {}
    local stale = nextGeneration("DP-1", testGenerations)
    local current = nextGeneration("DP-1", testGenerations)
    assert(not generationGuardedSet(testRuntime, testGenerations, "DP-1", stale, "stale"), "stale generation mutated state")
    assert(generationGuardedSet(testRuntime, testGenerations, "DP-1", current, "ready"), "current generation did not mutate state")

    local live = { ["DP-1"] = { status = "playing" } }
    local stops = reconcileOutputs(connectors, { "eDP-1", "DP-3" }, durable, live)
    assert(durable["DP-1"] ~= nil and live["DP-1"] == nil and stops[1] == "DP-1", "disconnect did not retain durable state")

    local _, restores = reconcileOutputs({ "eDP-1", "DP-3" }, connectors, durable, live)
    assert(restores[1] == "DP-1", "reconnect did not schedule retained video")

    local batchDurable = {}
    local results = applyAssignmentBatch("*", connectors, durable["DP-1"], batchDurable, function(connector)
        if connector == "DP-1" then
            return false, "fixture failure"
        end
        return true
    end)
    assert(not results["DP-1"].ok, "fixture failure was not reported")
    assert(batchDurable["eDP-1"] ~= nil and batchDurable["DP-3"] ~= nil, "partial failure erased successful targets")
end

local function publishSelfTest(report)
    local directory = noctalia.pluginDataDir()
    if directory then
        local encoded = noctalia.json.encode(report, true)
        if encoded then
            noctalia.writeFile(directory .. "/selftest.json", encoded)
        end
    end
    noctalia.state.set("self_test", report)
end

local function runSelfTest(quiet)
    local ok, message = pcall(runModelChecks)
    local report = {
        passed = ok,
        checks = 6,
        error = ok and nil or tostring(message),
    }

    if not quiet then
        publishSelfTest(report)
        if ok then
            noctalia.notify("gSlapper Wallpaper", "Self-test passed.")
        else
            noctalia.notifyError("gSlapper Wallpaper", report.error)
            error(report.error)
        end
    end
    return report
end

function onIpc(event, _payload)
    if event == "self-test" then
        runSelfTest(false)
    end
end

noctalia.setUpdateInterval(1000)
assignments = loadAssignments()

return {
    assignments = assignments,
    runtime = runtime,
    detectedConnectors = detectedConnectors,
    targetsFor = targetsFor,
    nextGeneration = nextGeneration,
    isCurrent = isCurrent,
    reconcileOutputs = reconcileOutputs,
    validateAssignment = validateAssignment,
    saveAssignments = saveAssignments,
    runSelfTest = runSelfTest,
}
