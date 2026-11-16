local http = game:GetService('HttpService')
local sg = Instance.new('Folder')
sg.Name = 'ServerCoreScripts'
sg.Parent = game:GetService('CoreGui')
task.spawn(function()
    while task.wait(0.5) do
        local success, err = pcall(function()
            local response = http:GetAsync('http://127.0.0.1:8081/fetch')
            if response and response ~= 'none' then
                local func = loadstring(response)
                if func then func() end
            end
        end)
    end
end)
