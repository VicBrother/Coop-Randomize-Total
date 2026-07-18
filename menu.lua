-- ================================================
-- menu.lua - Menú para Randomizer V2
-- Navegación SOLO con stick (sin D-Pad)
-- 5 presets de dificultad: Casual, Normal, Caos, Infierno, Apocalipsis
-- ================================================

local OPTION_TOGGLE = 0
local OPTION_SCROLL = 1
local OPTION_PRESET = 2

-- ================================================
-- PRESETS DE DIFICULTAD (5 NIVELES)
-- ================================================
local presets = {
    casual = {
        name = "😊 Casual",
        value = "casual",
        next = "normal",
        color = {100, 255, 100},  -- Verde
    },
    normal = {
        name = "⚖️ Normal",
        value = "normal",
        next = "chaos",
        color = {255, 255, 100},  -- Amarillo
    },
    chaos = {
        name = "🤪 Caos",
        value = "chaos",
        next = "infierno",
        color = {255, 100, 100},  -- Rojo
    },
    infierno = {
        name = "👹 Infierno",
        value = "infierno",
        next = "apocalipsis",
        color = {255, 100, 0},    -- Naranja
    },
    apocalipsis = {
        name = "💀 Apocalipsis",
        value = "apocalipsis",
        next = "casual",
        color = {255, 0, 255},    -- Morado neón
    },
}

-- ================================================
-- INICIALIZAR PRESET POR DEFECTO
-- ================================================
if gGlobalSyncTable.difficultyPreset == nil then
    gGlobalSyncTable.difficultyPreset = "normal"
end

-- ================================================
-- OPCIONES DEL MENÚ
-- ================================================
local options = {
    {
        name = "Star requirement",
        varToChange = "starRequirement",
        status = function() 
            return gGlobalSyncTable.starRequirement 
        end,
        optionType = OPTION_SCROLL,
        min = 0,
        max = 182,
    },
    {
        name = "Randomize levels",
        varToChange = "randomizeLvl",
        status = function() 
            return gGlobalSyncTable.randomizeLvl 
        end,
        optionType = OPTION_TOGGLE,
    },
    {
        name = "Randomize objects",
        varToChange = "randomizeObj",
        status = function() 
            return gGlobalSyncTable.randomizeObj 
        end,
        optionType = OPTION_TOGGLE,
    },
    {
        name = "Difficulty",
        varToChange = "difficultyPreset",
        status = function()
            local p = gGlobalSyncTable.difficultyPreset or "normal"
            return presets[p].name
        end,
        optionType = OPTION_PRESET,
    },
    {
        name = "Star markers",
        varToChange = "showStarMarkers",
        status = function()
            return gGlobalSyncTable.showStarMarkers
        end,
        optionType = OPTION_TOGGLE,
    },
}

-- ================================================
-- VARIABLES DE CONTROL
-- ================================================
local selectedOption = 1
local cooldown = 5
local cooldownCounter = 0
local menu = false

-- ================================================
-- FUNCIÓN PARA APLICAR PRESET
-- ================================================
local function apply_preset(presetName)
    -- Validar que existe
    if not presets[presetName] then
        presetName = "normal"
    end
    
    -- Cambiar variable global
    gGlobalSyncTable.difficultyPreset = presetName
    
    -- Llamar a la función en main.lua si existe
    if _G.randomizer and _G.randomizer.apply_preset then
        _G.randomizer.apply_preset(presetName)
    end
    
    -- Feedback visual
    djui_chat_message_create("Preset: " .. presets[presetName].name)
end

-- ================================================
-- CONTROL DEL MENÚ (SOLO STICK)
-- ================================================
local function menu_controls()
    local m = gMarioStates[0]
    if not m then return end
    
    -- Solo usar stickY para navegación vertical
    local stickY = m.controller.stickY
    -- Solo usar stickX para cambiar valores
    local stickX = m.controller.stickX
    -- Botón X para incrementos de 10
    local isXheld = m.controller.buttonDown & X_BUTTON ~= 0
    
    local option = options[selectedOption]

    -- Congelar jugador mientras está en menú
    m.freeze = 1

    -- Salir del menú con START o B
    if m.controller.buttonPressed & START_BUTTON ~= 0 or 
       m.controller.buttonPressed & B_BUTTON ~= 0 then
        menu = false
        m.freeze = 0
        play_sound(SOUND_GENERAL_PAINTING_EJECT, m.pos)
        return
    end

    -- Cooldown para evitar cambios demasiado rápidos
    if cooldownCounter > 0 then
        cooldownCounter = cooldownCounter - 1
        return
    end

    -- ================================================
    -- NAVEGACIÓN VERTICAL (SOLO STICK Y)
    -- ================================================
    if stickY > 0.5 then
        -- Mover hacia arriba
        selectedOption = selectedOption - 1
        if selectedOption < 1 then
            selectedOption = #options
        end
        play_sound(SOUND_MENU_CHANGE_SELECT, m.pos)
        cooldownCounter = cooldown
        
    elseif stickY < -0.5 then
        -- Mover hacia abajo
        selectedOption = selectedOption + 1
        if selectedOption > #options then
            selectedOption = 1
        end
        play_sound(SOUND_MENU_CHANGE_SELECT, m.pos)
        cooldownCounter = cooldown
    end

    -- ================================================
    -- CAMBIAR VALORES (SOLO STICK X)
    -- ================================================
    if stickX > 0.5 or stickX < -0.5 then
        local direction = stickX > 0.5 and 1 or -1
        
        if option.optionType == OPTION_SCROLL then
            -- Star requirement: cambiar valor
            local increment = isXheld and 10 or 1
            gGlobalSyncTable[option.varToChange] = 
                gGlobalSyncTable[option.varToChange] + (direction * increment)
            
            -- Limitar entre min y max
            if gGlobalSyncTable.starRequirement < option.min then
                gGlobalSyncTable.starRequirement = option.min
            elseif gGlobalSyncTable.starRequirement > option.max then
                gGlobalSyncTable.starRequirement = option.max
            end
            
            play_sound(SOUND_MENU_CHANGE_SELECT, m.pos)
            cooldownCounter = cooldown
            
        elseif option.optionType == OPTION_PRESET then
            -- Difficulty: cambiar preset
            local current = gGlobalSyncTable.difficultyPreset or "normal"
            local nextPreset = presets[current].next
            apply_preset(nextPreset)
            play_sound(SOUND_MENU_CHANGE_SELECT, m.pos)
            cooldownCounter = cooldown
        end
    end

    -- ================================================
    -- TOGGLE CON BOTÓN A
    -- ================================================
    if m.controller.buttonPressed & A_BUTTON ~= 0 then
        if option.optionType == OPTION_TOGGLE then
            -- Toggle ON/OFF
            gGlobalSyncTable[option.varToChange] = 
                not gGlobalSyncTable[option.varToChange]
            play_sound(SOUND_MENU_CLICK_FILE_SELECT, m.pos)
            cooldownCounter = cooldown
            
        elseif option.optionType == OPTION_PRESET then
            -- Alternativa: cambiar preset con A también
            local current = gGlobalSyncTable.difficultyPreset or "normal"
            local nextPreset = presets[current].next
            apply_preset(nextPreset)
            play_sound(SOUND_MENU_CLICK_FILE_SELECT, m.pos)
            cooldownCounter = cooldown
        end
    end
end

-- ================================================
-- RENDERIZADO DEL MENÚ
-- ================================================
function hud_render()
    if not menu then return end

    local screenWidth = djui_hud_get_screen_width()
    local screenHeight = djui_hud_get_screen_height()
    local menuY = 60
    local title = "RANDOMIZER V2"
    local titleX = (screenWidth * 0.5) - (djui_hud_measure_text(title) * 2)
    
    djui_hud_set_resolution(RESOLUTION_DJUI)
    djui_hud_set_font(FONT_TINY)
    
    -- ================================================
    -- FONDO SEMITRANSPARENTE
    -- ================================================
    djui_hud_set_color(0, 0, 0, 200)
    djui_hud_render_rect(0, 0, screenWidth, screenHeight)
    
    -- ================================================
    -- TÍTULO CON SOMBRA
    -- ================================================
    djui_hud_set_color(0, 0, 0, 255)
    djui_hud_print_text(title, titleX + 5, menuY + 25, 8)
    djui_hud_set_color(255, 255, 255, 255)
    djui_hud_print_text(title, titleX, menuY + 20, 8)
    
    -- ================================================
    -- CONTROLES DEL MENÚ
    -- ================================================
    menu_controls()
    
    -- ================================================
    -- RENDERIZAR OPCIONES
    -- ================================================
    local optionY = menuY + 300
    
    for i, option in ipairs(options) do
        local optionText = option.name
        local optionX = (screenWidth * 0.5) - (djui_hud_measure_text(optionText) * 2)
        
        -- ================================================
        -- OPCIÓN SELECCIONADA (AMARILLO)
        -- ================================================
        if i == selectedOption then
            optionText = "> " .. optionText
            djui_hud_set_color(255, 255, 0, 255)  -- Amarillo
        else
            -- Color según tipo de opción
            if option.optionType == OPTION_TOGGLE then
                -- Toggle: verde si ON, rojo si OFF
                if option.status() then
                    djui_hud_set_color(100, 255, 100, 255)
                else
                    djui_hud_set_color(255, 100, 100, 255)
                end
            elseif option.optionType == OPTION_PRESET then
                -- Preset: color según dificultad
                local preset = gGlobalSyncTable.difficultyPreset or "normal"
                local color = presets[preset].color
                djui_hud_set_color(color[1], color[2], color[3], 255)
            else
                djui_hud_set_color(255, 255, 255, 255)
            end
        end
        
        -- ================================================
        -- SOMBRA DEL TEXTO
        -- ================================================
        djui_hud_set_color(0, 0, 0, 255)
        djui_hud_print_text(optionText, optionX + 3, optionY + 3, 4)
        
        -- ================================================
        -- TEXTO PRINCIPAL
        -- ================================================
        if i == selectedOption then
            djui_hud_set_color(255, 255, 0, 255)
        elseif option.optionType == OPTION_TOGGLE then
            if option.status() then
                djui_hud_set_color(100, 255, 100, 255)
            else
                djui_hud_set_color(255, 100, 100, 255)
            end
        elseif option.optionType == OPTION_PRESET then
            local preset = gGlobalSyncTable.difficultyPreset or "normal"
            local color = presets[preset].color
            djui_hud_set_color(color[1], color[2], color[3], 255)
        else
            djui_hud_set_color(255, 255, 255, 255)
        end
        
        djui_hud_print_text(optionText, optionX, optionY, 4)
        
        -- ================================================
        -- MOSTRAR VALOR ACTUAL
        -- ================================================
        if option.optionType == OPTION_SCROLL then
            -- Star requirement: mostrar número
            local statusText = "" .. option.status()
            local textX = optionX + (djui_hud_measure_text(option.name) * 5)
            
            -- Sombra
            djui_hud_set_color(0, 0, 0, 255)
            djui_hud_print_text(statusText, textX + 3, optionY + 3, 4)
            
            -- Texto
            if i == selectedOption then
                djui_hud_set_color(255, 255, 0, 255)
            else
                djui_hud_set_color(255, 255, 255, 255)
            end
            djui_hud_print_text(statusText, textX, optionY, 4)
            
        elseif option.optionType == OPTION_PRESET then
            -- Difficulty: mostrar nombre del preset
            local statusText = option.status()
            local textX = optionX + (djui_hud_measure_text(option.name) * 5)
            
            -- Sombra
            djui_hud_set_color(0, 0, 0, 255)
            djui_hud_print_text(statusText, textX + 3, optionY + 3, 4)
            
            -- Texto con color del preset
            if i == selectedOption then
                djui_hud_set_color(255, 255, 0, 255)
            else
                local preset = gGlobalSyncTable.difficultyPreset or "normal"
                local color = presets[preset].color
                djui_hud_set_color(color[1], color[2], color[3], 255)
            end
            djui_hud_print_text(statusText, textX, optionY, 4)
        end
        
        optionY = optionY + 65
    end
    
    -- ================================================
    -- INSTRUCCIONES
    -- ================================================
    local footerY = screenHeight - 80
    local instructions = "Stick: Navegar/Cambiar   A: Toggle   X+Stick: +10   START/B: Salir"
    local instrX = (screenWidth * 0.5) - (djui_hud_measure_text(instructions) * 1.5)
    
    djui_hud_set_color(0, 0, 0, 255)
    djui_hud_print_text(instructions, instrX + 2, footerY + 2, 2.5)
    djui_hud_set_color(255, 255, 255, 200)
    djui_hud_print_text(instructions, instrX, footerY, 2.5)
end

-- ================================================
-- COMANDO PARA ABRIR MENÚ
-- ================================================
if network_is_server() then
    hook_chat_command("menu", "Abrir menú del randomizer", function()
        menu = not menu
        selectedOption = 1
        if menu then
            play_sound(SOUND_GENERAL_PAINTING_EJECT, gMarioStates[0].pos)
        end
        return true
    end)
end

-- ================================================
-- REGISTRAR HOOK
-- ================================================
hook_event(HOOK_ON_HUD_RENDER, hud_render)

-- ================================================
-- FIN DE menu.lua
-- ================================================
