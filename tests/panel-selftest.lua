noctalia = {
    setUpdateInterval = function() end,
    state = {
        get = function() return nil end,
        watch = function() end,
    },
}

local picker = dofile("gslapper/panel.luau")
local media = {}
for index = 1, 25 do
    media[index] = { name = tostring(index), kind = "image" }
end

local first, firstPage, pages = picker.paginate(media, 1)
local second, secondPage = picker.paginate(media, 2)
assert(#first == 24 and firstPage == 1 and pages == 2, "first page must contain 24 media")
assert(#second == 1 and second[1] == media[25] and secondPage == 2, "second page must contain the remainder")

local folders, separatedMedia = picker.partitionEntries({
    { name = "folder", kind = "directory" },
    media[1],
}, "")
assert(#folders == 1 and #separatedMedia == 1, "folders must not consume media page slots")

print("panel self-test: passed")
