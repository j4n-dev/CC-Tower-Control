local filesToDelete = {
    "lib/",
    "config.json",
    "node.cfg", 
    "registry.json",
    "server.lua",
    "client.lua", 
    "setup.lua",
    "startup.lua",
    "version"
}

for _, file in ipairs(filesToDelete) do
    if fs.exists(file) then
        fs.delete(file)
        print("Deleted: " .. file)
    else
        print("Not found: " .. file)
    end
end

print("Cleanup complete. Bye.")