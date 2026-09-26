function love.conf(t)
    t.identity = "rgmusic-demo"
    t.version = "11.5"
    t.console = false
    t.window.title = "RG Music Demo"
    t.window.width = 2048
    t.window.height = 768
    t.window.borderless = os.getenv("RGMUSIC_DEV") ~= "1"
    t.window.resizable = os.getenv("RGMUSIC_DEV") == "1"
    t.window.vsync = 1
    t.window.msaa = 0
    t.window.highdpi = false
    t.modules.audio = true
    t.modules.sound = true
    t.modules.physics = false
end
