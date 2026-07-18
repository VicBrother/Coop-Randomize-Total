-- name: ! Coop\\#5733FF\\ Rand\\#FF33A1\\omize\\#33A1FF\\r Total !
-- description: This mod is based off of the randomizer hack which randomizes object location, levels, music and more!

-- =============================================================================
-- [001] - CONFIGURACIÓN GLOBAL INICIAL
-- =============================================================================
gLevelValues.extendedPauseDisplay = true

for i = 0, MAX_PLAYERS - 1 do
    gPlayerSyncTable[i].entryCourse = nil
    gPlayerSyncTable[i].entryLevel = nil
end

-- =============================================================================
-- [002] - VARIABLES GLOBALES
-- =============================================================================
local frameCounter = 0
local isFirstPlay = true
local blorandom_state = 0
local entropyPool = 0
local entropyCounter = 0

-- Sistema de colores - historial para evitar repeticiones
local colorHistory = {}
local HISTORY_SIZE = 5

-- Tabla débil para limpieza automática de referencias a objetos
local objectData = setmetatable({}, { __mode = "k" })

-- Variables para el sistema de regeneración por START
local startHoldTimer = 0
local requiredHoldTime = 80
local startRegenerated = false
local currArea = 0
local currLevel = 0
local modsLoadedFlag = false

-- Flag de reposicionamiento en castillo tras morir/salir de nivel redirigido.
-- Evita el conflicto con el warp de muerte vanilla del engine.
local castleRepositionPending = nil

-- Última semilla aplicada. Permite a jugadores tardíos recibir y aplicar
-- automáticamente la semilla activa cuando el servidor la sincroniza.
local lastAppliedSeed = 0

-- Cola de cinemáticas de estrella pendientes para clientes en red.
-- Cada entrada: {x, y, z, level, area, timer} — el timer espera que el objeto
-- sincronizado llegue antes de buscar la estrella y disparar el cutscene.
local pendingStarCutscenes = {}

-- Comportamiento temporal para la cámara del comando /where.
-- Se auto-destruye tras ~5 segundos, terminando el cutscene automáticamente.
local id_bhvWhereCameraAnchor = nil

for i = 0, MAX_PLAYERS - 1 do
    gPlayerSyncTable[i].entryCourse = nil
    gPlayerSyncTable[i].entryLevel = nil
    gPlayerSyncTable[i].justExited = false  -- Flag para evitar re-warp al salir del nivel
end

-- =============================================================================
-- [003] - SISTEMA DE RNG (CORREGIDO)
-- =============================================================================
function blorandomseed(seed)
    blorandom_state = (seed or 0) % 4294967296
end

function blorandom(min, max)
    blorandom_state = (blorandom_state * 1664525 + 1013904223) % 4294967296
    local rand_value = (blorandom_state / 65536) % 32768 / 32767

    if min and max then
        return math.floor(rand_value * (max - min + 1)) + min
    elseif min then
        return math.floor(rand_value * min) + 1
    else
        return rand_value
    end
end

local function simpleLCG(seed, min, max)
    local hash = (seed * 1103515245 + 12345) % 2147483648
    local rand = hash / 2147483647

    if min and max then
        return math.floor(rand * (max - min + 1)) + min
    end
    return rand
end

local function sm64_random_u16()
    if random_u16 then return random_u16() end
    if not gRandomSeed then gRandomSeed = 0x12345678 end
    gRandomSeed = ((gRandomSeed * 0x41C64E6D) + 0x3039) % 4294967296
    return math.floor(gRandomSeed / 65536) % 65536
end

local function sm64_random_seed(seed)
    if random_seed then random_seed(seed % 65536)
    else gRandomSeed = seed % 65536 end
end

local function sm64_random_advance(steps)
    for _ = 1, (steps or 1) do sm64_random_u16() end
end

local function rotate_left(value, bits)
    bits = bits % 32
    local result = ((value * (2^bits)) % 4294967296) + math.floor(value / (2^(32-bits)))
    return math.min(result, 4294967295)
end

-- =============================================================================
-- [003.1] - ENTROPÍA CORREGIDA (SOLO SERVIDOR)
-- =============================================================================
local function accumulate_entropy()
    -- ✅ CORRECCIÓN: Solo el servidor genera entropía
    -- ✅ Usa función REAL del Data Sheet (Sección 13.2)
    if not network_is_server() then
        return  -- Los clientes NO generan entropía local
    end

    local m = gMarioStates[0]
    if not m then return end

    local rng = 0
    for i = 1, 4 do
        rng = rng ~ sm64_random_u16()
        rng = rotate_left(rng, 7)
    end

    local player = 0
    if m.pos then
        player = player ~ (math.floor(m.pos.x * 100) % 4294967296)
        player = player ~ (math.floor(m.pos.y * 100) % 4294967296)
        player = player ~ (math.floor(m.pos.z * 100) % 4294967296)
    end

    entropyPool = entropyPool ~ rng
    entropyPool = rotate_left(entropyPool, 13)
    entropyPool = entropyPool ~ player
    entropyPool = rotate_left(entropyPool, 17)
    entropyPool = entropyPool ~ entropyCounter
    entropyCounter = entropyCounter + 1
end

-- =============================================================================
-- [003.2] - GENERADOR DE SEMILLA (SIN CAMBIOS)
-- =============================================================================
local function generate_seed(oldSeed)
    local newSeed = oldSeed ~ entropyPool
    for i = 1, 8 do
        newSeed = newSeed ~ sm64_random_u16()
        newSeed = rotate_left(newSeed, 11)
    end
    newSeed = (newSeed * 0x9E3779B9) % 4294967296
    newSeed = newSeed % 2147483648
    return newSeed == 0 and 1 or newSeed
end

-- =============================================================================
-- [004] - CONFIGURACIÓN DE SUPERFICIES INVÁLIDAS
-- =============================================================================
local invalidSurfaces = {
    [SURFACE_INSTANT_QUICKSAND] = true,
    [SURFACE_INTANGIBLE] = true,
    [SURFACE_DEATH_PLANE] = true,
    [SURFACE_BURNING] = true,
    [SURFACE_VERTICAL_WIND] = true,
    [SURFACE_INSTANT_MOVING_QUICKSAND] = true,
    [SURFACE_INSTANT_WARP_1B] = true,
    [SURFACE_INSTANT_WARP_1C] = true,
    [SURFACE_INSTANT_WARP_1D] = true,
    [SURFACE_INSTANT_WARP_1E] = true,
    [SURFACE_WARP] = true,
}

local function is_surface_valid(surface)
    if surface ~= nil and not invalidSurfaces[surface.type] and
       surface.type ~= SURFACE_PAINTING_WARP_D3 and
       surface.type ~= SURFACE_PAINTING_WARP_FC then
        return true
    end
    return false
end

-- =============================================================================
-- [005] - VARIABLES DE SINCRONIZACIÓN GLOBAL
-- =============================================================================
gGlobalSyncTable.randomizeLvl = false
gGlobalSyncTable.randomizeObj = false
gGlobalSyncTable.starRequirement = 0
gGlobalSyncTable.menuOpen = false
gGlobalSyncTable.selectedOption = 1
gGlobalSyncTable.showStarMarkers = false
gGlobalSyncTable.difficultyPreset = "normal"
gGlobalSyncTable.seed = 1
gGlobalSyncTable.showStats = false

-- =============================================================================
-- [006] - CONSTANTES Y CONFIGURACIONES
-- =============================================================================
PACKET_SEED_CHANGE = 1
PACKET_MENU_TOGGLE = 2
PACKET_MENU_SCROLL = 3
PACKET_PRESET_CHANGE = 4
PACKET_STAR_SPAWN = 5

E_MODEL_TRANS_PIPE = smlua_model_util_get_id("trans_pipe_geo")

local levelHeights = {
    [LEVEL_BOB] = { maxHeight = 3000, hasWingCap = true, hasStructures = true },
    [LEVEL_WF] = { maxHeight = 2500, hasWingCap = true, hasStructures = true },
    [LEVEL_JRB] = { maxHeight = 1500, hasWingCap = true, hasStructures = true },
    [LEVEL_CCM] = { maxHeight = 2000, hasWingCap = true, hasStructures = true },
    [LEVEL_BBH] = { maxHeight = 1200, hasWingCap = false, hasStructures = true },
    [LEVEL_HMC] = { maxHeight = 800, hasWingCap = false, hasStructures = true },
    [LEVEL_LLL] = { maxHeight = 1500, hasWingCap = false, hasStructures = true },
    [LEVEL_SSL] = { maxHeight = 1800, hasWingCap = true, hasStructures = true },
    [LEVEL_DDD] = { maxHeight = 600, hasWingCap = false, hasStructures = true },
    [LEVEL_SL] = { maxHeight = 1600, hasWingCap = true, hasStructures = true },
    [LEVEL_WDW] = { maxHeight = 1000, hasWingCap = false, hasStructures = true },
    [LEVEL_TTM] = { maxHeight = 2800, hasWingCap = true, hasStructures = true },
    [LEVEL_THI] = { maxHeight = 3200, hasWingCap = true, hasStructures = true },
    [LEVEL_TTC] = { maxHeight = 2000, hasWingCap = false, hasStructures = true },
    [LEVEL_RR] = { maxHeight = 3500, hasWingCap = true, hasStructures = true },
    [LEVEL_BITDW] = { maxHeight = 1200, hasWingCap = false, hasStructures = true },
    [LEVEL_BITFS] = { maxHeight = 2000, hasWingCap = false, hasStructures = true },
    [LEVEL_BITS] = { maxHeight = 2500, hasWingCap = false, hasStructures = true },
    [LEVEL_PSS] = { maxHeight = 800, hasWingCap = false, hasStructures = false },
    [LEVEL_COTMC] = { maxHeight = 600, hasWingCap = false, hasStructures = false },
    [LEVEL_TOTWC] = { maxHeight = 2000, hasWingCap = true, hasStructures = true },
    [LEVEL_VCUTM] = { maxHeight = 500, hasWingCap = false, hasStructures = false },
    [LEVEL_WMOTR] = { maxHeight = 3000, hasWingCap = true, hasStructures = true },
    [LEVEL_SA] = { maxHeight = 400, hasWingCap = false, hasStructures = false },
    [LEVEL_CASTLE] = { maxHeight = 800, hasWingCap = false, hasStructures = true },
    [LEVEL_CASTLE_GROUNDS] = { maxHeight = 1000, hasWingCap = false, hasStructures = true },
    [LEVEL_CASTLE_COURTYARD] = { maxHeight = 800, hasWingCap = false, hasStructures = true },
}

local DEFAULT_MAX_HEIGHT = 1500
local DEFAULT_HAS_WING = false

local function get_level_data(levelNum)
    return levelHeights[levelNum] or {
        maxHeight = DEFAULT_MAX_HEIGHT,
        hasWingCap = DEFAULT_HAS_WING,
        hasStructures = true,
    }
end

local presets = {
    casual = {
        name = "😊 Casual",
        heightMultiplier = 0.3,
        minHeight = 100,
        starAttempts = 100,
        coinAttempts = 80,
        coinHeightMult = 0.8,
        yellowHeightMult = 0.7,
        allowFloating = false,
        requiresWingCap = false,
    },
    normal = {
        name = "⚖️ Normal",
        heightMultiplier = 0.6,
        minHeight = 80,
        starAttempts = 250,
        coinAttempts = 150,
        coinHeightMult = 1.0,
        yellowHeightMult = 1.0,
        allowFloating = false,
        requiresWingCap = false,
    },
    chaos = {
        name = "🤪 Caos",
        heightMultiplier = 1.0,
        minHeight = 50,
        starAttempts = 500,
        coinAttempts = 300,
        coinHeightMult = 1.5,
        yellowHeightMult = 1.8,
        allowFloating = true,
        requiresWingCap = false,
    },
    infierno = {
        name = "👹 Infierno",
        heightMultiplier = 2.0,
        minHeight = 30,
        starAttempts = 800,
        coinAttempts = 500,
        coinHeightMult = 2.5,
        yellowHeightMult = 3.0,
        allowFloating = true,
        requiresWingCap = true,
    },
    apocalipsis = {
        name = "💀 Apocalipsis",
        heightMultiplier = 3.0,
        minHeight = 0,
        starAttempts = 1200,
        coinAttempts = 800,
        coinHeightMult = 4.0,
        yellowHeightMult = 5.0,
        allowFloating = true,
        requiresWingCap = false,
    },
}

local STAR_CONFIG = {
    MIN_HEIGHT = presets.normal.minHeight,
    PREFERRED_HEIGHT = 250,
    RAYCAST_ATTEMPTS = presets.normal.starAttempts,
    MIN_DISTANCE_FROM_ORIGINAL = 300,
}

local COIN_CONFIG = {
    red_scattered = {
        RAYCAST_ATTEMPTS = 300,
        MIN_HEIGHT = 60,
        PREFERRED_HEIGHT = 100,
        SEARCH_RADIUS = 4000,
        SPACING = 600,
        HEIGHT_MULTIPLIER = 1.0,
    },
    yellow_formation = {
        RAYCAST_ATTEMPTS = 25,
        MIN_HEIGHT = 30,
        PREFERRED_HEIGHT = 60,
        FORMATION_RADIUS = 200,
        ANGLE_VARIATION = 45,
        RADIUS_VARIATION = 100,
        HEIGHT_MULTIPLIER = 1.0,
    },
}

function for_each_object_with_behavior(behavior, func_f)
    local obj = obj_get_first_with_behavior_id(behavior)
    while obj ~= nil do
        func_f(obj)
        obj = obj_get_next_with_same_behavior_id(obj)
    end
end

local config = {
    groundedObjects = {
        [id_bhvWarpPipe] = true,
        [id_bhvRockSolid] = true,
        [id_bhvMrI] = true,
        [id_bhvPiranhaPlant] = true,
        [id_bhvPushableMetalBox] = true,
        [id_bhvBreakableBox] = true,
        [id_bhvCoinFormation] = true,
        [id_bhvFallingPillar] = true,
        [id_bhvPillarBase] = true,
        [id_bhvBobomb] = true,
        [id_bhvGoomba] = true,
        [id_bhvWoodenPost] = true,
        [id_bhvMessagePanel] = true,
        [id_bhvToadMessage] = true,
        [id_bhvWhompKingBoss] = true,
        [id_bhvSmallWhomp] = true,
        [id_bhvThwomp] = true,
        [id_bhvThwomp2] = true,
        [id_bhvTree] = true,
        [id_bhvKickableBoard] = true,
    },
    skipBehaviors = {
        [id_bhvWaterLevelDiamond] = true,
        [id_bhvDoor] = true,
        [id_bhvUkikiCageStar] = true,
        [id_bhvUkikiCage] = true,
        [id_bhvDddWarp] = true,
        [id_bhvBigBoulderGenerator] = true,
        [id_bhvBigBoulder] = true,
        [id_bhvTreasureChestTop] = true,
        [id_bhvStarDoor] = true,
        [id_bhvDoorWarp] = true,
        [id_bhvAirborneWarp] = true,
        [id_bhvSpinAirborneWarp] = true,
        [id_bhvSnowmansHead] = true,
        [id_bhvSnowmansBodyCheckpoint] = true,
        [id_bhvSnowmansBottom] = true,
        [id_bhvJrbFloatingBox] = true,
        [id_bhvSwingPlatform] = true,
        [id_bhvWarp] = true,
        [id_bhvControllablePlatform] = true,
        [id_bhvPurpleSwitchHiddenBoxes] = true,
        [id_bhvHiddenObject] = true,
        [id_bhvPitBowlingBall] = true,
        [id_bhvBobBowlingBallSpawner] = true,
        [id_bhvThiBowlingBallSpawner] = true,
        [id_bhvTtmBowlingBallSpawner] = true,
        [id_bhvFreeBowlingBall] = true,
        [id_bhvKoopaRaceEndpoint] = true,
        [id_bhvKoopa] = true,
        [id_bhvOpenableCageDoor] = true,
        [id_bhvWaterLevelPillar] = true,
        [id_bhvCannon] = true,
        [id_bhvCannonClosed] = true,
        [id_bhvCannonBarrel] = true,
        [id_bhvCannonBarrelBubbles] = true,
        [id_bhvDDDPole] = true,
        [id_bhvSeesawPlatform] = true,
        [id_bhvChainChomp] = true,
        [id_bhvChainChompChainPart] = true,
        [id_bhvChainChompGate] = true,
        [id_bhvCheckerboardPlatformSub] = true,
        [id_bhvGiantPole] = true,
        [id_bhvHmcElevatorPlatform] = true,
        [id_bhvAnotherElavator] = true,
        [id_bhvTower] = true,
        [id_bhvTowerPlatformGroup] = true,
        [id_bhvTowerDoor] = true,
        [id_bhvDonutPlatform] = true,
        [id_bhvDonutPlatformSpawner] = true,
        [id_bhvBbhTiltingTrapPlatform] = true,
        [id_bhvPoleGrabbing] = true,
        [id_bhvDddMovingPole] = true,
        [id_bhvBowsersSub] = true,
        [id_bhvBowserBomb] = true,
        [id_bhvBowser] = true,
        [id_bhvCastleFloorTrap] = true,
        [id_bhvCastleFlagWaving] = true,
        [id_bhvFallingBowserPlatform] = true,
        [id_bhvTiltingBowserLavaPlatform] = true,
        [id_bhvWaterBombCannon] = true,
        [id_bhvMerryGoRound] = true,
        [id_bhvMerryGoRoundBigBoo] = true,
        [id_bhvMerryGoRoundBooManager] = true,
        [id_bhvClockHourHand] = true,
        [id_bhvClockMinuteHand] = true,
        [id_bhvDecorativePendulum] = true,
        [id_bhvCapSwitchBase] = true,
        [id_bhvCapSwitch] = true,
        [id_bhvHiddenBlueCoin] = true,
        [id_bhvBlueCoinSwitch] = true,
        [id_bhvBigSnowmanWhole] = true,
        [id_bhvFloorSwitchHiddenObjects] = true,
        [id_bhvFloorSwitchHardcodedModel] = true,
        [id_bhvFloorSwitchGrills] = true,
        [id_bhvFloorSwitchAnimatesObject] = true,
        [id_bhvHiddenStaircaseStep] = true,
        [id_bhvFerrisWheelAxle] = true,
        [id_bhvFerrisWheelPlatform] = true,
        [id_bhvPlatformOnTrack] = true,
        [id_bhvTTCRotatingSolid] = true,
        [id_bhvTTC2DRotator] = true,
        [id_bhvTTCCog] = true,
        [id_bhvTTCElevator] = true,
        [id_bhvTTCMovingBar] = true,
        [id_bhvTTCPendulum] = true,
        [id_bhvTTCPitBlock] = true,
        [id_bhvHauntedBookshelfManager] = true,
        [id_bhvHauntedBookshelf] = true,
        [id_bhvTTCSpinner] = true,
        [id_bhvTTCTreadmill] = true,
        [id_bhvLargeBomp] = true,
        [id_bhvSmallBomp] = true,
        [id_bhvWfBreakableWallLeft] = true,
        [id_bhvRacingPenguin] = true,
        [id_bhvWfBreakableWallRight] = true,
        [id_bhvWfRotatingWoodenPlatform] = true,
        [id_bhvRotatingPlatform] = true,
        [id_bhvSlidingPlatform2] = true,
        [id_bhvCoffin] = true,
        [id_bhvCoffinSpawner] = true,
        [id_bhvWfSlidingPlatform] = true,
        [id_bhvWfSlidingTowerPlatform] = true,
        [id_bhvLllSinkingRockBlock] = true,
        [id_bhvLllHexagonalMesh] = true,
        [id_bhvStaticCheckeredPlatform] = true,
        [id_bhvCheckerboardElevatorGroup] = true,
        [id_bhvOctagonalPlatformRotating] = true,
        [id_bhvPyramidTop] = true,
        [id_bhvPyramidPillarTouchDetector] = true,
        [id_bhvJetStream] = true,
        [id_bhvJetStreamRingSpawner] = true,
        [id_bhvJetStreamWaterRing] = true,
        [id_bhvPyramidElevator] = true,
        [id_bhvToxBox] = true,
        [id_bhvAnimatesOnFloorSwitchPress] = true,
        [id_bhvTumblingBridgePlatform] = true,
        [id_bhvBbhTumblingBridge] = true,
        [id_bhvFadingWarp] = true,
        [id_bhvSunkenShipPart] = true,
        [id_bhvInSunkenShip2] = true,
        [id_bhvShipPart3] = true,
        [id_bhvInSunkenShip] = true,
        [id_bhvInSunkenShip3] = true,
        [id_bhvSunkenShipPart2] = true,
        [id_bhvSunkenShipSetRotation] = true,
        [id_bhvOpenableGrill] = true,
        [id_bhvUnagi] = true,
        [id_bhvLllBowserPuzzle] = true,
        [id_bhvLllDrawbridge] = true,
        [id_bhvLllDrawbridgeSpawner] = true,
        [id_bhvLllRollingLog] = true,
        [id_bhvLllRotatingHexagonalPlatform] = true,
        [id_bhvLllRotatingHexagonalRing] = true,
        [id_bhvLllRotatingBlockWithFireBars] = true,
        [id_bhvLllSinkingRectangularPlatform] = true,
        [id_bhvLllTiltingInvertedPyramid] = true,
        [id_bhvLllSinkingSquarePlatforms] = true,
        [id_bhvLllMovingOctagonalMeshPlatform] = true,
        [id_bhvLllWoodPiece] = true,
        [id_bhvLllFloatingWoodBridge] = true,
        [id_bhvTtmRollingLog] = true,
        [id_bhvWfSolidTowerPlatform] = true,
        [id_bhvSquarishPathMoving] = true,
        [id_bhvSquarishPathParent] = true,
        [id_bhvWdwExpressElevator] = true,
        [id_bhvBitfsSinkingCagePlatform] = true,
        [id_bhvBitfsSinkingPlatforms] = true,
        [id_bhvMeshElevator] = true,
        [id_bhvSquishablePlatform] = true,
        [id_bhvWfTumblingBridge] = true,
        [id_bhvSLWalkingPenguin] = true,
        [id_bhvBulletBill] = true,
        [id_bhvBulletBillCannon] = true,
        [id_bhvSnowMoundSpawn] = true,
        [id_bhvWdwExpressElevatorPlatform] = true,
        [id_bhvStaticObject] = true,
    },
}

-- =============================================================================
-- [007] - ESTADÍSTICAS DE RAYCAST
-- =============================================================================
local raycastStats = {
    redCoins = { attempts = 0, successes = 0, fallbacks = 0 },
    stars = { attempts = 0, successes = 0, fallbacks = 0 },
    totalAttempts = 0,
    totalSuccesses = 0,
    totalFallbacks = 0,
}

-- =============================================================================
-- [008] - FUNCIONES DE UTILIDAD
-- =============================================================================
local levelHeightCache = {}

function apply_preset(presetName)
    local p = presets[presetName]
    if not p then
        djui_chat_message_create("\\#FFAA00\\⚠️ Preset desconocido, usando Normal")
        presetName = "normal"
        p = presets.normal
    end

    STAR_CONFIG.MIN_HEIGHT = p.minHeight
    STAR_CONFIG.RAYCAST_ATTEMPTS = p.starAttempts
    COIN_CONFIG.red_scattered.RAYCAST_ATTEMPTS = p.coinAttempts
    COIN_CONFIG.yellow_formation.RAYCAST_ATTEMPTS = math.floor(p.coinAttempts * 0.8)

    COIN_CONFIG.red_scattered.HEIGHT_MULTIPLIER = p.coinHeightMult
    COIN_CONFIG.yellow_formation.HEIGHT_MULTIPLIER = p.yellowHeightMult

    gGlobalSyncTable.difficultyPreset = presetName

    levelHeightCache = {}

    djui_chat_message_create("Preset cambiado a: " .. p.name)
end

local function calculate_max_star_height(levelNum, presetName)
    local cacheKey = tostring(levelNum) .. "_" .. (presetName or "normal")
    
    if levelHeightCache[cacheKey] then
        return levelHeightCache[cacheKey]
    end
    
    local levelData = get_level_data(levelNum)
    local p = presets[presetName] or presets.normal

    local baseMax = levelData.maxHeight
    local maxAllowed = baseMax * p.heightMultiplier

    if p.requiresWingCap and not levelData.hasWingCap then
        maxAllowed = baseMax
    end

    maxAllowed = math.max(maxAllowed, p.minHeight)
    
    levelHeightCache[cacheKey] = maxAllowed
    return maxAllowed
end

-- =============================================================================
-- [009] - SISTEMA DE COLORES VIBRANTES
-- =============================================================================
local dominantColors = {
    {255, 0, 0},
    {0, 255, 0},
    {0, 0, 255},
    {255, 255, 0},
    {255, 0, 255},
    {0, 255, 255},
    {255, 128, 0},
    {255, 192, 203},
    {128, 0, 128},
    {255, 215, 0},
    {173, 216, 230},
    {255, 255, 255},
}

local function color_distance_sq(c1, c2)
    local dr = c1.r - c2.r
    local dg = c1.g - c2.g
    local db = c1.b - c2.b
    return dr*dr + dg*dg + db*db
end

local function is_color_similar_to_recent(r, g, b)
    local threshold_sq = 10000
    
    for _, color in ipairs(colorHistory) do
        local distSq = color_distance_sq({r = r, g = g, b = b}, color)
        if distSq < threshold_sq then
            return true
        end
    end
    return false
end

local function add_color_to_history(r, g, b)
    table.insert(colorHistory, {r = r, g = g, b = b})
    if #colorHistory > HISTORY_SIZE then
        table.remove(colorHistory, 1)
    end
end

local function get_vibrant_color()
    local r, g, b
    local attempts = 0
    local maxAttempts = 100
    local bestColor = nil
    local bestDistance = 0
    
    if not dominantColors or #dominantColors == 0 then
        return blorandom(100, 255), blorandom(100, 255), blorandom(100, 255)
    end
    
    if #colorHistory == 0 then
        local idx = blorandom(1, #dominantColors)
        r, g, b = dominantColors[idx][1], dominantColors[idx][2], dominantColors[idx][3]
        add_color_to_history(r, g, b)
        return r, g, b
    end
    
    repeat
        attempts = attempts + 1
        local roll = blorandom(1, 100)

        if roll <= 70 then
            local idx = blorandom(1, #dominantColors)
            r, g, b = dominantColors[idx][1], dominantColors[idx][2], dominantColors[idx][3]
        else
            r = blorandom(150, 255)
            g = blorandom(150, 255)
            b = blorandom(150, 255)
        end
        
        local minDist = 999*999
        for _, histColor in ipairs(colorHistory) do
            local distSq = color_distance_sq({r = r, g = g, b = b}, histColor)
            minDist = math.min(minDist, distSq)
        end
        
        if minDist > bestDistance then
            bestDistance = minDist
            bestColor = {r = r, g = g, b = b}
        end
        
        if minDist > 150*150 then
            add_color_to_history(r, g, b)
            return r, g, b
        end
        
    until attempts > maxAttempts
    
    if bestColor then
        add_color_to_history(bestColor.r, bestColor.g, bestColor.b)
        return bestColor.r, bestColor.g, bestColor.b
    end
    
    return 255, 255, 255
end

-- =============================================================================
-- [010] - MÚSICA Y SKYBOX
-- =============================================================================
local musicTable = {
    SEQ_LEVEL_GRASS,
    SEQ_LEVEL_SPOOKY,
    SEQ_LEVEL_HOT,
    SEQ_LEVEL_BOSS_KOOPA,
    SEQ_LEVEL_BOSS_KOOPA_FINAL,
    SEQ_LEVEL_SNOW,
    SEQ_LEVEL_WATER,
    SEQ_LEVEL_SLIDE,
    SEQ_LEVEL_INSIDE_CASTLE,
    SEQ_LEVEL_KOOPA_ROAD,
    SEQ_LEVEL_UNDERGROUND,
    SEQ_MENU_FILE_SELECT,
    SEQ_MENU_TITLE_SCREEN,
    SEQ_EVENT_MERRY_GO_ROUND,
    SEQ_EVENT_PIRANHA_PLANT,
    SEQ_EVENT_POWERUP,
    SEQ_EVENT_METAL_CAP,
    SEQ_EVENT_ENDLESS_STAIRS,
    SEQ_EVENT_CUTSCENE_CREDITS,
    SEQ_EVENT_BOSS,
}

local skyboxTable = {
    BACKGROUND_OCEAN_SKY,
    BACKGROUND_ABOVE_CLOUDS,
    BACKGROUND_BELOW_CLOUDS,
    BACKGROUND_DESERT,
    BACKGROUND_FLAMING_SKY,
    BACKGROUND_PURPLE_SKY,
    BACKGROUND_GREEN_SKY,
    BACKGROUND_HAUNTED,
    BACKGROUND_SNOW_MOUNTAINS,
}

function seq_load(player, seq)
    if player ~= SEQ_PLAYER_SFX and gGlobalSyncTable.randomizeLvl then
        if musicTable and #musicTable > 0 then
            return musicTable[blorandom(1, #musicTable)]
        end
    end
    return seq
end

local function get_random_skybox()
    if skyboxTable and #skyboxTable > 0 then
        local random_index = blorandom(1, #skyboxTable)
        return skyboxTable[random_index]
    end
    return BACKGROUND_OCEAN_SKY
end

-- =============================================================================
-- [011] - SISTEMA DE PUNTOS DE EXCLUSIÓN
-- =============================================================================
local currHack = "vanilla"

for i, mod in pairs(gActiveMods or {}) do
    if mod.enabled then
        if mod.incompatible and mod.incompatible:find("romhack") then
            djui_popup_create(mod.name.." Detected!", 1)
            currHack = mod.name:lower()
        end
    end
end

local vanillaAvoidancePoints = {
    [LEVEL_CASTLE_GROUNDS] = {
        {area = 1, pointA = {x = 513, y = 803, z = -3668}, pointB = {x = -512, y = 6000, z = -3206}},
    },
    [LEVEL_DDD] = {
        {area = 1, pointA = {x = 3628, y = 1000, z = -401}, pointB = {x = -1771, y = -2756, z = -402}},
        {area = 2, pointA = {x = 3628, y = 1000, z = -401}, pointB = {x = -1771, y = -2756, z = -402}},
    },
}

local StarRoadAvoidancePoints = {
    [LEVEL_BOB] = {
        {area = 1, pointA = {x = 7397, y = -2495, z = -7795}, pointB = {x = -7223, y = -99999, z = 6606}},
    },
}

local avoidancePoints = {
    ["vanilla"] = vanillaAvoidancePoints,
    ["star road"] = StarRoadAvoidancePoints,
}

local function is_within_avoidance_point(level, area, position)
    if not avoidancePoints[currHack] then return false end

    local points = avoidancePoints[currHack][level]

    if not points then return false end

    for _, point in ipairs(points) do
        if point.area == area then
            local pA, pB = point.pointA, point.pointB
            if position.x >= math.min(pA.x, pB.x) and position.x <= math.max(pA.x, pB.x) and
               position.y >= math.min(pA.y, pB.y) and position.y <= math.max(pA.y, pB.y) and
               position.z >= math.min(pA.z, pB.z) and position.z <= math.max(pA.z, pB.z) then
                return true
            end
        end
    end

    return false
end

-- =============================================================================
-- [012] - SISTEMA DE BÚSQUEDA SEGURA
-- =============================================================================
local function findSafePositions(findFunction, fallbackFunction, neededCount, maxAttempts, minSuccessRate, objectType)
    local foundPositions = {}
    local attempts = 0
    local successes = 0
    -- NOTA: Se elimina el corte anticipado para usar TODOS los intentos
    -- Esto maximiza la calidad de las posiciones encontradas

    if neededCount <= 0 then return {} end

    -- FASE 1: Búsqueda activa con raycast - usa TODOS los intentos
    while #foundPositions < neededCount and attempts < maxAttempts do
        attempts = attempts + 1

        local newPos = findFunction(attempts, #foundPositions)

        if newPos then
            table.insert(foundPositions, newPos)
            successes = successes + 1
            -- ELIMINADO: corte anticipado por porcentaje
        end

        if attempts % 50 == 0 then
            blorandom()
        end
    end

    -- FASE 2: Fallbacks - solo para posiciones no encontradas
    local fallbacksUsed = 0
    while #foundPositions < neededCount do
        local fallbackPos = fallbackFunction(#foundPositions + 1, attempts + fallbacksUsed)
        if fallbackPos then
            table.insert(foundPositions, fallbackPos)
            fallbacksUsed = fallbacksUsed + 1
        else
            local m = gMarioStates[0]
            if m and m.pos then
                table.insert(foundPositions, {
                    x = m.pos.x,
                    y = m.pos.y + 300,
                    z = m.pos.z
                })
            else
                table.insert(foundPositions, {
                    x = 0,
                    y = 1000,
                    z = 0
                })
            end
        end
    end

    -- Actualizar estadísticas según tipo de objeto
    if objectType == "red_coins" then
        raycastStats.redCoins.attempts = raycastStats.redCoins.attempts + attempts
        raycastStats.redCoins.successes = raycastStats.redCoins.successes + successes
        raycastStats.redCoins.fallbacks = raycastStats.redCoins.fallbacks + fallbacksUsed
    elseif objectType == "star" then
        raycastStats.stars.attempts = raycastStats.stars.attempts + attempts
        raycastStats.stars.successes = raycastStats.stars.successes + successes
        raycastStats.stars.fallbacks = raycastStats.stars.fallbacks + fallbacksUsed
    end

    raycastStats.totalAttempts = raycastStats.totalAttempts + attempts
    raycastStats.totalSuccesses = raycastStats.totalSuccesses + successes
    raycastStats.totalFallbacks = raycastStats.totalFallbacks + fallbacksUsed

    return foundPositions
end

-- =============================================================================
-- [013] - RANDOMIZACIÓN DE MONEDAS ROJAS
-- =============================================================================
local function score_coin_position(x, y, z, config, placed_positions, maxAllowedHeight)
    local floor_y = find_floor_height(x, y, z)
    if not floor_y or floor_y < -8000 then return -1 end

    local ceil_y = find_ceil_height(x, y + 200, z)
    if not ceil_y then ceil_y = maxAllowedHeight + 500 end

    local vertical_space = ceil_y - floor_y
    if vertical_space < config.MIN_HEIGHT + 50 then
        return -1
    end

    if y > maxAllowedHeight then
        return -1
    end

    local score = 0

    if vertical_space > 500 then
        score = score + 40
    elseif vertical_space > 300 then
        score = score + 20
    end

    if placed_positions and config.SPACING then
        for _, pos in ipairs(placed_positions) do
            local dx = x - pos.x
            local dz = z - pos.z
            local dy = y - pos.y
            local distSq = dx*dx + dz*dz + dy*dy
            if distSq < config.SPACING * config.SPACING then
                return -1
            end
        end
    end

    local height_from_floor = y - floor_y
    local target_height = config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER
    local height_diff = math.abs(height_from_floor - target_height)

    if height_diff < 20 then
        score = score + 50
    elseif height_diff < 50 then
        score = score + 25
    elseif height_from_floor < config.MIN_HEIGHT then
        return -1
    end

    return score
end

local function randomize_red_coins_scattered(o, num_coins)
    local config = COIN_CONFIG.red_scattered
    if not config then return false end

    local center_x, center_y, center_z = o.oPosX, o.oPosY, o.oPosZ
    local level = gNetworkPlayers[0].currLevelNum
    local area = gNetworkPlayers[0].currAreaIndex
    local maxAllowedHeight = calculate_max_star_height(level, gGlobalSyncTable.difficultyPreset)

    obj_mark_for_deletion(o)

    local function findOneCoin(attempt, alreadyFound)
        blorandomseed(gGlobalSyncTable.seed + attempt * 100 + alreadyFound * 50)

        local dirX = blorandom(-32768, 32768)
        local dirY = blorandom(-32768, 32768)
        local dirZ = blorandom(-32768, 32768)

        local origin_x = center_x + blorandom(-config.SEARCH_RADIUS, config.SEARCH_RADIUS)
        local origin_z = center_z + blorandom(-config.SEARCH_RADIUS, config.SEARCH_RADIUS)
        local origin_y = center_y + blorandom(-1000, 1000)

        local ray = collision_find_surface_on_ray(origin_x, origin_y, origin_z, dirX, dirY, dirZ)

        if ray and ray.surface and is_surface_valid(ray.surface) then
            local normal = ray.surface.normal
            if normal and normal.y > 0.85 then
                local hit_x, hit_y, hit_z = ray.hitPos.x, ray.hitPos.y, ray.hitPos.z

                if not is_within_avoidance_point(level, area, {x = hit_x, y = hit_y, z = hit_z}) then
                    local floor_y = find_floor_height(hit_x, hit_y, hit_z)
                    if floor_y and floor_y > -8000 then
                        local target_height = config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER
                        local coin_y = hit_y + target_height

                        if coin_y <= maxAllowedHeight then
                            return {x = hit_x, y = coin_y, z = hit_z}
                        end
                    end
                end
            end
        end
        return nil
    end

    local function fallbackCoin(index, totalAttempts)
        local angle = blorandom(0, 360) * math.pi / 180
        local radius = blorandom(200, 800)
        local fallback_x = center_x + math.cos(angle) * radius
        local fallback_z = center_z + math.sin(angle) * radius
        local floor_y = find_floor_height(fallback_x, center_y, fallback_z)
        local target_height = config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER

        if floor_y and floor_y > -8000 then
            return {x = fallback_x, y = floor_y + target_height, z = fallback_z}
        else
            return {
                x = center_x + blorandom(-200, 200),
                y = math.min(center_y + target_height, maxAllowedHeight),
                z = center_z + blorandom(-200, 200)
            }
        end
    end

    local positions = findSafePositions(
        findOneCoin,
        fallbackCoin,
        num_coins,
        1500,
        0.75,
        "red_coins"
    )

    for i, pos in ipairs(positions) do
        spawn_sync_object(id_bhvRedCoin, E_MODEL_RED_COIN,
            pos.x, pos.y, pos.z, function(obj)
            obj.oBehParams = i
        end)
    end

    return true
end

-- =============================================================================
-- [014] - RANDOMIZACIÓN DE MONEDAS AMARILLAS
-- =============================================================================
local function randomize_yellow_formation(o, num_coins)
    local config = COIN_CONFIG.yellow_formation
    if not config then return false end

    local center_x, center_y, center_z = o.oPosX, o.oPosY, o.oPosZ
    local level = gNetworkPlayers[0].currLevelNum
    local area = gNetworkPlayers[0].currAreaIndex
    local maxAllowedHeight = calculate_max_star_height(level, gGlobalSyncTable.difficultyPreset)

    obj_mark_for_deletion(o)

    local group_center = nil
    local best_center_score = -1
    local center_attempts = 100

    for attempt = 1, center_attempts do
        local dirX = blorandom(-32768, 32768)
        local dirY = blorandom(-32768, 32768)
        local dirZ = blorandom(-32768, 32768)

        local origin_x = center_x + blorandom(-4000, 4000)
        local origin_y = center_y + blorandom(-1000, 1000)
        local origin_z = center_z + blorandom(-4000, 4000)

        local ray = collision_find_surface_on_ray(origin_x, origin_y, origin_z, dirX, dirY, dirZ)

        if ray and ray.surface and is_surface_valid(ray.surface) then
            local normal = ray.surface.normal
            if normal and normal.y > 0.85 then
                local hit_x, hit_y, hit_z = ray.hitPos.x, ray.hitPos.y, ray.hitPos.z

                if not is_within_avoidance_point(level, area, {x = hit_x, y = hit_y, z = hit_z}) then
                    local floor_y = find_floor_height(hit_x, hit_y, hit_z)
                    local ceil_y = find_ceil_height(hit_x, hit_y + 300, hit_z)

                    if floor_y and floor_y > -8000 and ceil_y then
                        local vertical_space = ceil_y - floor_y

                        if vertical_space >= 150 then
                            local score = vertical_space

                            local dx = hit_x - center_x
                            local dz = hit_z - center_z
                            local dist_to_original_sq = dx*dx + dz*dz
                            
                            if dist_to_original_sq < 4000000 then
                                score = score + 500
                            elseif dist_to_original_sq < 16000000 then
                                score = score + 200
                            end

                            if math.abs(hit_x) < 7000 and math.abs(hit_z) < 7000 then
                                score = score + 300
                            end

                            if score > best_center_score then
                                best_center_score = score
                                local target_height = config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER
                                group_center = {
                                    x = hit_x,
                                    y = hit_y + target_height,
                                    z = hit_z,
                                    floor_y = floor_y,
                                    ceil_y = ceil_y
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    if not group_center then
        for attempt = 1, 20 do
            local test_x = center_x + blorandom(-1000, 1000)
            local test_z = center_z + blorandom(-1000, 1000)
            local floor_y = find_floor_height(test_x, center_y, test_z)

            if floor_y and floor_y > -8000 then
                local ceil_y = find_ceil_height(test_x, floor_y + 200, test_z)
                if ceil_y and (ceil_y - floor_y) >= 150 then
                    local target_height = config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER
                    group_center = {
                        x = test_x,
                        y = floor_y + target_height,
                        z = test_z,
                        floor_y = floor_y,
                        ceil_y = ceil_y
                    }
                    break
                end
            end
        end
    end

    if not group_center then
        local m = gMarioStates[0]
        if m and m.pos then
            local floor_y = find_floor_height(m.pos.x, m.pos.y, m.pos.z)
            if floor_y and floor_y > -8000 then
                local target_height = config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER
                group_center = {
                    x = m.pos.x,
                    y = floor_y + target_height,
                    z = m.pos.z,
                    floor_y = floor_y,
                    ceil_y = floor_y + 500
                }
            else
                group_center = {
                    x = center_x,
                    y = math.min(center_y + (config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER), maxAllowedHeight),
                    z = center_z,
                    floor_y = center_y,
                    ceil_y = center_y + 500
                }
            end
        else
            group_center = {
                x = center_x,
                y = math.min(center_y + (config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER), maxAllowedHeight),
                z = center_z,
                floor_y = center_y,
                ceil_y = center_y + 500
            }
        end
    end

    local pattern = blorandom(1, 4)

    for i = 1, num_coins do
        local coin_x, coin_z
        local angle = (i - 1) * (360 / num_coins)
        local angle_rad = angle * math.pi / 180

        if pattern == 1 then
            local radius = config.FORMATION_RADIUS + blorandom(-30, 30)
            coin_x = group_center.x + math.cos(angle_rad) * radius
            coin_z = group_center.z + math.sin(angle_rad) * radius

        elseif pattern == 2 then
            local radius = config.FORMATION_RADIUS + blorandom(-60, 60)
            local angle_var = angle_rad + (blorandom(-20, 20) * math.pi / 180)
            coin_x = group_center.x + math.cos(angle_var) * radius
            coin_z = group_center.z + math.sin(angle_var) * radius

        elseif pattern == 3 then
            local radius = blorandom(50, 150)
            local random_angle = blorandom(0, 360) * math.pi / 180
            coin_x = group_center.x + math.cos(random_angle) * radius
            coin_z = group_center.z + math.sin(random_angle) * radius

        else
            local t = (i - 1) / (num_coins - 1)
            if num_coins == 1 then t = 0 end
            local arc_angle = blorandom(-60, 60) * math.pi / 180
            local radius = config.FORMATION_RADIUS * 1.5
            local base_angle = blorandom(0, 360) * math.pi / 180
            local final_angle = base_angle + arc_angle * (t - 0.5) * 2
            coin_x = group_center.x + math.cos(final_angle) * radius
            coin_z = group_center.z + math.sin(final_angle) * radius
        end

        local floor_y = find_floor_height(coin_x, group_center.y, coin_z)
        if not floor_y or floor_y < -8000 then
            floor_y = group_center.floor_y
        end

        local target_height = config.PREFERRED_HEIGHT * config.HEIGHT_MULTIPLIER
        local coin_height = floor_y + target_height
        coin_height = math.min(coin_height, maxAllowedHeight)

        if not is_within_avoidance_point(level, area, {x = coin_x, y = coin_height, z = coin_z}) then
            spawn_sync_object(id_bhvCoin, E_MODEL_COIN, coin_x, coin_height, coin_z, nil)
        else
            spawn_sync_object(id_bhvCoin, E_MODEL_COIN,
                group_center.x, group_center.y, group_center.z, nil)
        end
    end

    return true
end

-- =============================================================================
-- [015] - MANEJADOR DE FORMACIONES DE MONEDAS
-- =============================================================================
local function handle_coin_formation(o)
    local bhv_id = get_id_from_behavior(o.behavior)

    if bhv_id == id_bhvCoinFormation and o.oBehParams2ndByte == 1 then
        return randomize_red_coins_scattered(o, 8)
    end

    if bhv_id == id_bhvCoinFormation then
        local num_coins = o.oBehParams & 0xFF
        if num_coins >= 3 and num_coins <= 12 then
            return randomize_yellow_formation(o, num_coins)
        end
    end

    return false
end

-- =============================================================================
-- [016] - SISTEMA DE PINTURAS Y TEXTURAS
-- =============================================================================
local sPaintingToVanillaTexture = {
    [gPaintingValues.bob_painting.id] = {
        top = "inside_castle_seg7_texture_0700A800",
        bottom = "inside_castle_seg7_texture_0700B800"
    },
    [gPaintingValues.wf_painting.id] = {
        top = "inside_castle_seg7_texture_0700E800",
        bottom = "inside_castle_seg7_texture_0700F800"
    },
    [gPaintingValues.jrb_painting.id] = {
        top = "inside_castle_seg7_texture_07010800",
        bottom = "inside_castle_seg7_texture_07011800"
    },
    [gPaintingValues.ccm_painting.id] = {
        top = "inside_castle_seg7_texture_0700C800",
        bottom = "inside_castle_seg7_texture_0700D800"
    },
    [gPaintingValues.hmc_painting.id] = {
        top = "inside_castle_seg7_texture_07016800",
        bottom = "inside_castle_seg7_texture_07016800",
    },
    [gPaintingValues.lll_painting.id] = {
        top = "inside_castle_seg7_texture_07013800",
        bottom = "inside_castle_seg7_texture_07012800"
    },
    [gPaintingValues.ssl_painting.id] = {
        top = "inside_castle_seg7_texture_07014800",
        bottom = "inside_castle_seg7_texture_07015800"
    },
    [gPaintingValues.ddd_painting.id] = {
        top = "inside_castle_seg7_texture_07017000",
        bottom = "inside_castle_seg7_texture_07017000",
    },
    [gPaintingValues.wdw_painting.id] = {
        top = "inside_castle_seg7_texture_07017800",
        bottom = "inside_castle_seg7_texture_07018800"
    },
    [gPaintingValues.sl_painting.id] = {
        top = "inside_castle_seg7_texture_0701F800",
        bottom = "inside_castle_seg7_texture_07020800"
    },
    [gPaintingValues.ttm_painting.id] = {
        top = "inside_castle_seg7_texture_0701B800",
        bottom = "inside_castle_seg7_texture_0701C800"
    },
    [gPaintingValues.thi_tiny_painting.id] = {
        top = "inside_castle_seg7_texture_07019800",
        bottom = "inside_castle_seg7_texture_0701A800"
    },
    [gPaintingValues.thi_huge_painting.id] = {
        top = "inside_castle_seg7_texture_07019800",
        bottom = "inside_castle_seg7_texture_0701A800"
    },
    [gPaintingValues.ttc_painting.id] = {
        top = "inside_castle_seg7_texture_0701D800",
        bottom = "inside_castle_seg7_texture_0701E800"
    },
}

local levelToPainting = {
    [LEVEL_BOB] = {top = "bob_top", bottom = "bob_bottom"},
    [LEVEL_WF] = {top = "wf_top", bottom = "wf_bottom"},
    [LEVEL_JRB] = {top = "jrb_top", bottom = "jrb_bottom"},
    [LEVEL_CCM] = {top = "ccm_top", bottom = "ccm_bottom"},
    [LEVEL_BBH] = {top = "bbh_top", bottom = "bbh_bottom"},
    [LEVEL_HMC] = {top = "hmc_top", bottom = "hmc_bottom"},
    [LEVEL_LLL] = {top = "lll_top", bottom = "lll_bottom"},
    [LEVEL_SSL] = {top = "ssl_top", bottom = "ssl_bottom"},
    [LEVEL_DDD] = {top = "ddd_top", bottom = "ddd_bottom"},
    [LEVEL_SL] = {top = "sl_top", bottom = "sl_bottom"},
    [LEVEL_WDW] = {top = "wdw_top", bottom = "wdw_bottom"},
    [LEVEL_TTM] = {top = "ttm_top", bottom = "ttm_bottom"},
    [LEVEL_THI] = {top = "thi_top", bottom = "thi_bottom"},
    [LEVEL_TTC] = {top = "ttc_top", bottom = "ttc_bottom"},
    [LEVEL_RR] = {top = "rr_top", bottom = "rr_bottom"},
    [LEVEL_PSS] = {top = "pss_top", bottom = "pss_bottom"},
    [LEVEL_SA] = {top = "sa_top", bottom = "sa_bottom"},
    [LEVEL_WMOTR] = {top = "wmotr_top", bottom = "wmotr_bottom"},
    [LEVEL_TOTWC] = {top = "totwc_top", bottom = "totwc_bottom"},
    [LEVEL_COTMC] = {top = "cotmc_top", bottom = "cotmc_bottom"},
    [LEVEL_VCUTM] = {top = "vcutm_top", bottom = "vcutm_bottom"},
    [LEVEL_BITDW] = {top = "bitdw_top", bottom = "bitdw_bottom"},
    [LEVEL_BITFS] = {top = "bitfs_top", bottom = "bitfs_bottom"},
}

local paintingToCourse = {
    bob_painting = COURSE_BOB,
    wf_painting = COURSE_WF,
    ccm_painting = COURSE_CCM,
    jrb_painting = COURSE_JRB,
    ssl_painting = COURSE_SSL,
    lll_painting = COURSE_LLL,
    hmc_painting = COURSE_HMC,
    ddd_painting = COURSE_DDD,
    wdw_painting = COURSE_WDW,
    ttm_painting = COURSE_TTM,
    sl_painting = COURSE_SL,
    thi_huge_painting = COURSE_THI,
    thi_tiny_painting = COURSE_THI,
    ttc_painting = COURSE_TTC,
    cotmc_painting = COURSE_COTMC,
}

local function set_painting_texture()
    if not gGlobalSyncTable.randomizeLvl then
        -- Modo vanilla: resetear todas las pinturas a su textura original del engine.
        for pName, _ in pairs(paintingToCourse) do
            local p = gPaintingValues[pName]
            if p and sPaintingToVanillaTexture[p.id] then
                texture_override_reset(sPaintingToVanillaTexture[p.id].top)
                texture_override_reset(sPaintingToVanillaTexture[p.id].bottom)
            end
        end
        return
    end

    -- Modo randomizer: aplicar textura del nivel destino en cada pintura.
    for pName, course in pairs(paintingToCourse) do
        local p = gPaintingValues[pName]
        if p and sPaintingToVanillaTexture[p.id] then
            local targetLevel = levelTable[course] or course
            local targetTexture = levelToPainting[targetLevel]

            if targetTexture then
                texture_override_reset(sPaintingToVanillaTexture[p.id].top)
                texture_override_reset(sPaintingToVanillaTexture[p.id].bottom)
                texture_override_set(sPaintingToVanillaTexture[p.id].top, get_texture_info(targetTexture.top))
                texture_override_set(sPaintingToVanillaTexture[p.id].bottom, get_texture_info(targetTexture.bottom))
            end
        end
    end
end

-- =============================================================================
-- [017] - SHUFFLE DE NIVELES Y DIÁLOGOS
-- =============================================================================
local dialogNames = {
    "BobombBuddyBob1Dialog", "BobombBuddyBob2Dialog", "BobombBuddyOther1Dialog", "BobombBuddyOther2Dialog",
    "Bowser1DefeatedDialog", "Bowser1Dialog", "Bowser2DefeatedDialog", "Bowser2Dialog",
    "Bowser3Defeated120StarsDialog", "Bowser3DefeatedDialog", "Bowser3Dialog",
    "CapswitchBaseDialog", "CapswitchMetalDialog", "CapswitchVanishDialog", "CapswitchWingDialog",
    "CastleEnterDialog", "CollectedStarDialog", "DefaultCutsceneDialog",
    "DoorNeed1StarDialog", "DoorNeed30StarsDialog", "DoorNeed3StarsDialog", "DoorNeed50StarsDialog",
    "DoorNeed70StarsDialog", "DoorNeed8StarsDialog", "DoorNeedKeyDialog",
    "EyerokDefeatedDialog", "EyerokIntroDialog", "GhostHuntAfterDialog", "GhostHuntDialog",
    "HootIntroDialog", "HootTiredDialog", "HundredCoinsDialog", "IntroPipeDialog",
    "KeyDoor1DontHaveDialog", "KeyDoor1HaveDialog", "KeyDoor2DontHaveDialog", "KeyDoor2HaveDialog",
    "KingBobombCheatDialog", "KingBobombDefeatDialog", "KingBobombIntroDialog",
    "KingWhompDefeatDialog", "KingWhompDialog",
    "KoopaQuickBobStartDialog", "KoopaQuickBobWinDialog", "KoopaQuickCheatedDialog",
    "KoopaQuickLostDialog", "KoopaQuickThiStartDialog", "KoopaQuickThiWinDialog",
    "LakituIntroDialog", "MetalCourseDialog", "Mips1Dialog", "Mips2Dialog", "PeachLetterDialog",
    "RacingPenguinBigStartDialog", "RacingPenguinCheatDialog", "RacingPenguinLostDialog",
    "RacingPenguinStartDialog", "RacingPenguinWinDialog",
    "SnowmanHeadAfterDialog", "SnowmanHeadBodyDialog", "SnowmanHeadDialog", "SnowmanWindDialog",
    "StarCollectionBaseDialog", "StarDoorDialog",
    "ToadStar1AfterDialog", "ToadStar1Dialog", "ToadStar2AfterDialog", "ToadStar2Dialog",
    "ToadStar3AfterDialog", "ToadStar3Dialog",
    "TuxieMotherBabyFoundDialog", "TuxieMotherBabyWrongDialog", "TuxieMotherDialog",
    "UkikiCageDialog", "UkikiCapGiveDialog", "UkikiCapStealDialog", "UkikiHeldDialog",
    "VanishCourseDialog", "WigglerAttack1Dialog", "WigglerAttack2Dialog", "WigglerAttack3Dialog",
    "WigglerDialog", "WingCourseDialog", "YoshiDialog"
}

local unshuffledDialogTable = {}

for i = DIALOG_000, DIALOG_168 do
    unshuffledDialogTable[i] = i
end

-- Guardamos los valores ORIGINALES de los diálogos del engine antes de cualquier shuffle,
-- para que cada llamada a apply_shuffle siempre parta de los valores vanilla.
local originalDialogValues = {}
for _, name in ipairs(dialogNames) do
    originalDialogValues[name] = gBehaviorValues.dialogs[name]
end

local unshuffledLevelTable = {
    [COURSE_BOB]   = LEVEL_BOB,
    [COURSE_WF]    = LEVEL_WF,
    [COURSE_JRB]   = LEVEL_JRB,
    [COURSE_CCM]   = LEVEL_CCM,
    [COURSE_BBH]   = LEVEL_BBH,
    [COURSE_HMC]   = LEVEL_HMC,
    [COURSE_LLL]   = LEVEL_LLL,
    [COURSE_SSL]   = LEVEL_SSL,
    [COURSE_DDD]   = LEVEL_DDD,
    [COURSE_SL]    = LEVEL_SL,
    [COURSE_WDW]   = LEVEL_WDW,
    [COURSE_TTM]   = LEVEL_TTM,
    [COURSE_THI]   = LEVEL_THI,
    [COURSE_TTC]   = LEVEL_TTC,
    [COURSE_RR]    = LEVEL_RR,
    [COURSE_PSS]   = LEVEL_PSS,
    [COURSE_SA]    = LEVEL_SA,
    [COURSE_WMOTR] = LEVEL_WMOTR,
    [COURSE_TOTWC] = LEVEL_TOTWC,
    [COURSE_COTMC] = LEVEL_COTMC,
    [COURSE_VCUTM] = LEVEL_VCUTM,
    [COURSE_BITDW] = LEVEL_BITDW,
    [COURSE_BITFS] = LEVEL_BITFS,
}

local sFloorsToBowserLevels = {
    {
        levels = {COURSE_BOB, COURSE_WF, COURSE_JRB, COURSE_CCM, COURSE_BBH, COURSE_PSS, COURSE_SA, COURSE_TOTWC, COURSE_BITDW},
        bowser = LEVEL_BITDW
    },
    {
        levels = {COURSE_SSL, COURSE_LLL, COURSE_HMC, COURSE_DDD, COURSE_BITFS, COURSE_VCUTM},
        bowser = LEVEL_BITFS
    },
}

local levelsToSkip = {
    [LEVEL_BOWSER_1] = true,
    [LEVEL_BOWSER_2] = true,
    [LEVEL_BOWSER_3] = true,
    [LEVEL_BITS] = true,
    [LEVEL_CASTLE_GROUNDS] = true,
    [LEVEL_CASTLE_COURTYARD] = true,
    [LEVEL_CASTLE] = true,
    [LEVEL_ENDING] = true,
}

function shuffle_table(t, seed)
    local keys = {}
    local values = {}

    blorandomseed(seed)

    for k, v in pairs(t) do
        table.insert(keys, k)
        table.insert(values, v)
    end

    table.sort(keys)
    for i, k in ipairs(keys) do
        values[i] = t[k]
    end

    for i = #values, 2, -1 do
        local j = blorandom(1, i)
        values[i], values[j] = values[j], values[i]
    end

    local shuffled = {}
    for i, k in ipairs(keys) do
        shuffled[k] = values[i]
    end

    return shuffled
end

function ensure_bowser_access(levelTable, seed)
    for _, floor in ipairs(sFloorsToBowserLevels) do
        local bowserLevel = floor.bowser
        local leadsToBowser = false
        local bowserSource = nil

        for _, level in ipairs(floor.levels) do
            if levelTable[level] == bowserLevel then
                leadsToBowser = true
                break
            end
        end

        if not leadsToBowser then
            for src, dest in pairs(levelTable) do
                if dest == bowserLevel then
                    bowserSource = src
                    break
                end
            end

            if bowserSource then
                local swapTarget = floor.levels[blorandom(1, #floor.levels)]
                levelTable[bowserSource], levelTable[swapTarget] = levelTable[swapTarget], bowserLevel
            end
        end
    end
end

levelTable = {}
dialogTable = {}

local function apply_shuffle()
    local doShuffle = gGlobalSyncTable.randomizeLvl and not isFirstPlay

    if not doShuffle then
        -- Primera carga O modo vanilla: usar tabla sin shufflear (niveles en orden normal).
        levelTable = {}
        for course, level in pairs(unshuffledLevelTable) do
            levelTable[course] = level
        end
        dialogTable = {}
        for i = DIALOG_000, DIALOG_168 do
            dialogTable[i] = i
        end
        if isFirstPlay then
            isFirstPlay = false
        end
    else
        -- Modo randomizer activo: shufflear según la semilla actual.
        levelTable = shuffle_table(unshuffledLevelTable, gGlobalSyncTable.seed)
        ensure_bowser_access(levelTable, gGlobalSyncTable.seed)
        dialogTable = shuffle_table(unshuffledDialogTable, gGlobalSyncTable.seed)
    end

    -- Salud de bosses: valor vanilla (3) en modo normal, random en randomizer.
    if gGlobalSyncTable.randomizeLvl or gGlobalSyncTable.randomizeObj then
        gBehaviorValues.KingBobombHealth = blorandom(2, 10)
        gBehaviorValues.KingWhompHealth = blorandom(2, 10)
        gLevelValues.coinsRequiredForCoinStar = blorandom(50, 100)
    else
        gBehaviorValues.KingBobombHealth = 3
        gBehaviorValues.KingWhompHealth = 3
        gLevelValues.coinsRequiredForCoinStar = 100
    end

    -- Siempre aplicar el shuffle sobre los valores ORIGINALES del engine,
    -- nunca sobre valores ya shuffleados (evita corrupción acumulativa en llamadas múltiples).
    for _, name in ipairs(dialogNames) do
        local originalValue = originalDialogValues[name]
        if originalValue ~= nil then
            gBehaviorValues.dialogs[name] = dialogTable[originalValue] or originalValue
        end
    end
end

-- =============================================================================
-- [018] - RANDOMIZACIÓN DE OBJETOS
-- =============================================================================
local obj_get_first_with_behavior_id = obj_get_first_with_behavior_id
local obj_get_next_with_same_behavior_id = obj_get_next_with_same_behavior_id
local find_floor_height = find_floor_height
local find_ceil_height = find_ceil_height
local blorandom = blorandom
local math_sqrt = math.sqrt
local math_min = math.min
local math_max = math.max
local table_insert = table.insert

local function randomize_dialog_if_needed(o)
    if o.oInteractType and (o.oInteractType & INTERACT_TEXT ~= 0 or
       (o.oInteractionSubtype and (o.oInteractionSubtype & INT_SUBTYPE_SIGN ~= 0 or
        o.oInteractionSubtype & INT_SUBTYPE_NPC ~= 0))) then
        if dialogTable[o.oBehParams2ndByte] then
            o.oBehParams2ndByte = dialogTable[o.oBehParams2ndByte]
        end
    end
end

local function randomize(o)
    randomize_dialog_if_needed(o)

    if handle_coin_formation(o) then
        return true
    end

    local bhv_id = get_id_from_behavior(o.behavior)
    if config.skipBehaviors[bhv_id] or bhv_id >= id_bhv_max_count then
        return false
    end

    local originalPos = {x = o.oPosX, y = o.oPosY, z = o.oPosZ}
    objectData[o] = {originalPos = originalPos, randomized = false}

    local numRaycasts = 45
    local validHitPositions = {}
    local level = gNetworkPlayers[0].currLevelNum
    local area = gNetworkPlayers[0].currAreaIndex

    for i = 1, numRaycasts do
        local dirX = blorandom(-32768, 32768)
        local dirY = blorandom(-32768, 32768)
        local dirZ = blorandom(-32768, 32768)

        local ray = collision_find_surface_on_ray(
            blorandom(-6000, 6000),
            o.oPosY + blorandom(-500, 500),
            blorandom(-6000, 6000),
            dirX, dirY, dirZ
        )

        if ray and ray.surface and is_surface_valid(ray.surface) then
            local normal = ray.surface.normal
            if normal and normal.y > 0.85 then
                local hitPos = ray.hitPos
                local valid = true

                for _, prevHitPos in ipairs(validHitPositions) do
                    local dx = hitPos.x - prevHitPos.x
                    local dy = hitPos.y - prevHitPos.y
                    local dz = hitPos.z - prevHitPos.z
                    local distSq = dx*dx + dy*dy + dz*dz
                    if distSq <= 90000 then
                        valid = false
                        break
                    end
                end

                local dx = hitPos.x - originalPos.x
                local dy = hitPos.y - originalPos.y
                local dz = hitPos.z - originalPos.z
                local distToOriginalSq = dx*dx + dy*dy + dz*dz
                if distToOriginalSq <= 1000000 then
                    valid = false
                end

                if is_within_avoidance_point(level, area, hitPos) then
                    valid = false
                end

                if valid then
                    table_insert(validHitPositions, hitPos)
                    o.oPosX = hitPos.x
                    o.oPosY = hitPos.y
                    o.oPosZ = hitPos.z
                    objectData[o].randomized = true
                    break
                end
            end
        end
    end

    if objectData[o].randomized then
        if config.groundedObjects and config.groundedObjects[bhv_id] then
            local floorY = find_floor_height(o.oPosX, o.oPosY, o.oPosZ)
            if floorY and floorY > -8000 then
                o.oPosY = floorY
            end
        else
            local floorY = find_floor_height(o.oPosX, o.oPosY, o.oPosZ)
            local ceilY = find_ceil_height(o.oPosX, o.oPosY, o.oPosZ)
            if floorY and floorY > -8000 and ceilY then
                local minY = floorY + 50
                local maxY = math_min(floorY + 800, ceilY - 50)
                if maxY > minY then
                    o.oPosY = blorandom(minY, maxY)
                end
            end
        end
        bhv_init_room()
        cur_obj_set_home_once()
        
        -- 🔧 ACTUALIZAR ESTADÍSTICAS PARA MONEDAS ROJAS INDIVIDUALES
        if bhv_id == id_bhvRedCoin then
            raycastStats.redCoins.attempts = raycastStats.redCoins.attempts + 1
            raycastStats.redCoins.successes = raycastStats.redCoins.successes + 1
            raycastStats.totalAttempts = raycastStats.totalAttempts + 1
            raycastStats.totalSuccesses = raycastStats.totalSuccesses + 1
        end
    end

    return objectData[o].randomized
end

function randomize_all_objects()
    for objList = 0, NUM_OBJ_LISTS - 1 do
        local o = obj_get_first(objList)
        while o do
            local nextObj = obj_get_next(o)
            randomize(o)
            o = nextObj
        end
    end
end

-- =============================================================================
-- [019] - SISTEMA DE ESTRELLAS
-- =============================================================================
local function is_from_bully(star_spawn_obj)
    if not star_spawn_obj then return false end
    local parent = star_spawn_obj.parentObj
    if not parent then return false end

    local bhv_id = get_id_from_behavior(parent.behavior)
    return bhv_id == id_bhvSmallBully or
           bhv_id == id_bhvBigBully or
           bhv_id == id_bhvBigBullyWithMinions
end

local function find_random_star_position(originalPos, seed, levelNum)
    local savedState = blorandom_state
    blorandomseed(seed)

    local level = levelNum or gNetworkPlayers[0].currLevelNum
    local maxAllowedHeight = calculate_max_star_height(level, gGlobalSyncTable.difficultyPreset)

    local function findOneStarPosition(attempt)
        local dirX = blorandom(-32768, 32768)
        local dirY = blorandom(-32768, 32768)
        local dirZ = blorandom(-32768, 32768)

        local ray = collision_find_surface_on_ray(
            blorandom(-6000, 6000),
            blorandom(0, 4000),
            blorandom(-6000, 6000),
            dirX, dirY, dirZ
        )

        if ray and ray.surface and is_surface_valid(ray.surface) then
            local normal = ray.surface.normal
            if normal and normal.y > 0.85 then
                local hitPos = ray.hitPos

                if hitPos.y <= maxAllowedHeight then
                    local floorY = find_floor_height(hitPos.x, hitPos.y, hitPos.z)
                    local ceilY = find_ceil_height(hitPos.x, hitPos.y, hitPos.z)

                    if floorY and floorY > -8000 and ceilY then
                        if (ceilY - floorY) >= STAR_CONFIG.MIN_HEIGHT then
                            local starY = hitPos.y + STAR_CONFIG.PREFERRED_HEIGHT
                            starY = math_min(starY, ceilY - 50)

                            if starY <= maxAllowedHeight then
                                return {x = hitPos.x, y = starY, z = hitPos.z}
                            end
                        end
                    end
                end
            end
        end
        return nil
    end

    local function fallbackStarPosition(index, totalAttempts)
        local m = gMarioStates[0]
        if m and m.pos then
            local floorY = find_floor_height(m.pos.x, m.pos.y, m.pos.z)
            if floorY and floorY > -8000 then
                return {x = m.pos.x, y = m.pos.y + STAR_CONFIG.PREFERRED_HEIGHT, z = m.pos.z}
            end
        end
        return {x = originalPos.x, y = originalPos.y + STAR_CONFIG.PREFERRED_HEIGHT, z = originalPos.z}
    end

    local positions = findSafePositions(
        findOneStarPosition,
        fallbackStarPosition,
        1,
        500,
        0.90,
        "star"
    )

    blorandom_state = savedState
    return positions[1]
end

local function spawn_star_with_cutscene(x, y, z, behParams)
    if not x or not y or not z then return nil end

    local star = spawn_sync_object(id_bhvSpawnedStar, E_MODEL_STAR, x, y, z,
        function(obj)
            obj.oBehParams = behParams
            obj.oBehParams2ndByte = 0
        end)

    if star then
        -- El servidor reproduce la cinemática localmente de inmediato.
        cutscene_object(CUTSCENE_STAR_SPAWN, star)
        cur_obj_play_sound_2(SOUND_GENERAL_STAR_APPEARS)

        -- Notificar a todos los clientes en el mismo nivel para que también
        -- reproduzcan la cinemática cuando el objeto sincronizado llegue.
        if network_is_server() then
            network_send(true, {
                id      = PACKET_STAR_SPAWN,
                x       = x,
                y       = y,
                z       = z,
                level   = gNetworkPlayers[0].currLevelNum,
                area    = gNetworkPlayers[0].currAreaIndex,
            })
        end
    end

    return star
end

local function star_spawn_init(o)
    local m = nearest_mario_state_to_object(o)
    if not m then return end

    local originalPos = {x = o.oPosX, y = o.oPosY, z = o.oPosZ}
    local spawn_x, spawn_y, spawn_z

    if not gGlobalSyncTable.randomizeObj then
        spawn_x, spawn_y, spawn_z = originalPos.x, originalPos.y, originalPos.z
    else
        if is_from_bully(o) then
            spawn_x, spawn_y, spawn_z = m.pos.x, m.pos.y + 300, m.pos.z
        else
            local seed = gGlobalSyncTable.seed + (o.oBehParams or 0)
            local levelNum = gNetworkPlayers[0].currLevelNum
            local randomPos = find_random_star_position(originalPos, seed, levelNum)

            if randomPos and randomPos.x and randomPos.y and randomPos.z then
                spawn_x, spawn_y, spawn_z = randomPos.x, randomPos.y, randomPos.z
            else
                spawn_x, spawn_y, spawn_z = m.pos.x, m.pos.y + 300, m.pos.z
            end
        end
    end

    if network_is_server() then
        spawn_star_with_cutscene(spawn_x, spawn_y, spawn_z, o.oBehParams or 0)
    end

    obj_mark_for_deletion(o)
end

-- =============================================================================
-- [020] - FUNCIONES AUXILIARES DE OBJETOS
-- =============================================================================
local function break_box_in_water(o)
    local m = nearest_mario_state_to_object(o)
    if m and m.action == ACT_WATER_PUNCH and obj_check_hitbox_overlap(o, m.marioObj) and o.oAction == 2 then
        o.oExclamationBoxForce = true
        o.oAction = 3
        o.oExclamationBoxForce = false
        network_send_object(o, true)
    end
end

function invis_pipe(o)
    if obj_has_model_extended(o, E_MODEL_NONE) ~= 0 then
        obj_set_model_extended(o, E_MODEL_TRANS_PIPE)
    end
end

local function chest_number_init(o)
    o.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
    obj_set_billboard(o)
end

local function chest_number_loop(o)
    local chest = o.parentObj
    if chest == nil or chest.activeFlags == ACTIVE_FLAG_DEACTIVATED then
        obj_mark_for_deletion(o)
        return
    end

    obj_set_pos(o, chest.header.gfx.pos.x, chest.header.gfx.pos.y + 200.0 * chest.header.gfx.scale.y, chest.header.gfx.pos.z)
    obj_set_angle(o, 0, 0, 0)
    obj_scale(o, 1.0)
    o.oAnimState = chest.oBehParams2ndByte
    o.oBehParams2ndByte = o.oAnimState
    o.header.gfx.node.flags = chest.header.gfx.node.flags
end

local id_bhvChestNumber = hook_behavior(nil, OBJ_LIST_DEFAULT, true, chest_number_init, chest_number_loop, "bhvRandomizerChestNumber")

local function spawn_chest_number(o)
    if not o then return end

    local chestNumber = obj_get_first_with_behavior_id(id_bhvStarNumber)
    local found = false

    while chestNumber do
        if chestNumber.parentObj == o then
            found = true
            break
        end
        chestNumber = obj_get_next_with_same_behavior_id(chestNumber)
    end

    if not found then
        chestNumber = spawn_non_sync_object(id_bhvChestNumber, E_MODEL_TRANSPARENT_STAR, o.oPosX, o.oPosY, o.oPosZ, nil)
    end

    if chestNumber and o then
        chestNumber.parentObj = o
        chestNumber.activeFlags = chestNumber.activeFlags | ACTIVE_FLAG_INITIATED_TIME_STOP
    end
end

local function treasure_chest_bottom(o)
    if o.oTimer <= 0 and o.oAction <= 0 then
        randomize(o)
        local floorHeight = find_floor_height(o.oPosX, o.oPosY, o.oPosZ)
        if floorHeight and floorHeight > -8000 then
            o.oPosY = floorHeight
        end
        spawn_chest_number(o)
    end
end

local function treasure_chest_top(o)
    if o.oTimer <= 0 and o.oAction <= 0 then
        if o.parentObj then
            obj_copy_pos_and_angle(o, o.parentObj)
            obj_set_parent_relative_pos(o, 0, 102, -77)
            obj_build_relative_transform(o)
        end
    end
end

local function whomp_init(o)
    if o.oAction == 5 then
        if o.oPosY == find_floor_height(o.oPosX, o.oPosY, o.oPosZ) then
            o.oAction = 6
        end
    end
end

-- =============================================================================
-- [021] - SISTEMA DE REGENERACIÓN POR START
-- =============================================================================
local START_BUTTON = 0x1000

local function prevent_peach_letter_cutscene(m)
    if m.action == 0x13000400 then
        if m.usedObj and get_id_from_behavior(m.usedObj.behavior) == id_bhvPeachLetter then
            set_mario_action(m, ACT_IDLE, 0)

            if m.usedObj and m.usedObj.oBehParams then
                spawn_star_with_cutscene(m.pos.x, m.pos.y + 300, m.pos.z, m.usedObj.oBehParams)
            end

            djui_chat_message_create("\\#00FF00\\¡Carta de Peach omitida!")
            return true
        end
    end
    return false
end

-- =============================================================================
-- [022] - EVENTOS ESPECIALES POR SEMILLA
-- =============================================================================
local function check_special_seed(seed)
    if seed == 12345 then
        djui_popup_create("🎉 MODO SECRETO ACTIVADO - Estrellas extras!", 2)
        return {
            message = "🎉 MODO SECRETO",
            effect = function()
                local m = gMarioStates[0]
                for i = 1, 3 do
                    local x = m.pos.x + blorandom(-1000, 1000)
                    local z = m.pos.z + blorandom(-1000, 1000)
                    local floorY = find_floor_height(x, m.pos.y, z)
                    if floorY and floorY > -8000 then
                        spawn_star_with_cutscene(x, floorY + 300, z, 0)
                    end
                end
            end
        }
    elseif seed % 100 == 69 then
        return {
            message = "😏 MODO TRAVIESO",
            effect = function()
                djui_chat_message_create("¡Busca las monedas escondidas!")
            end
        }
    elseif seed == 0x7FFFFFFE then
        return {
            message = "🔥 MODO CAOS TOTAL",
            effect = function()
                gGlobalSyncTable.randomizeLvl = true
                gGlobalSyncTable.randomizeObj = true
                apply_preset("apocalipsis")
            end
        }
    end
    return nil
end

-- =============================================================================
-- [023] - COMANDO /WHERE
-- =============================================================================
local function find_and_highlight_nearest_star(m)
    local closestStar = nil
    local minDist = math.huge
    local secondClosest = nil
    local secondMinDist = math.huge

    local star = obj_get_first_with_behavior_id(id_bhvSpawnedStar)
    while star do
        local dx = star.oPosX - m.pos.x
        local dy = star.oPosY - m.pos.y
        local dz = star.oPosZ - m.pos.z
        local distSq = dx*dx + dy*dy + dz*dz

        if distSq < minDist then
            secondClosest = closestStar
            secondMinDist = minDist
            minDist = distSq
            closestStar = star
        elseif distSq < secondMinDist then
            secondMinDist = distSq
            secondClosest = star
        end

        star = obj_get_next_with_same_behavior_id(star)
    end

    if closestStar then
        return closestStar, math_sqrt(minDist), secondClosest, secondClosest and math_sqrt(secondMinDist) or nil
    end
    return closestStar, nil, secondClosest, nil
end

-- =============================================================================
-- [024] - PROCESAMIENTO DE OBJETOS ESPECIALES
-- =============================================================================

local function process_special_objects()
    for_each_object_with_behavior(id_bhvExclamationBox, break_box_in_water)
    for_each_object_with_behavior(id_bhvHiddenStarTrigger, function(o)
        spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES, o.oPosX, o.oPosY, o.oPosZ, nil)
    end)
    for_each_object_with_behavior(id_bhvFirePiranhaPlant, function(o)
        if o.oBehParams2ndByte > 0 then
            spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES, o.oPosX, o.oPosY, o.oPosZ, nil)
        end
    end)
end

-- =============================================================================
-- [025] - HOOK MARIO UPDATE
-- =============================================================================
local djui_hud_set_font = djui_hud_set_font
local djui_hud_set_color = djui_hud_set_color
local djui_hud_print_text = djui_hud_print_text
local spawn_non_sync_object = spawn_non_sync_object
local network_is_server = network_is_server
local warp_to_castle = warp_to_castle
local warp_to_level = warp_to_level

local function mario_update(m)
    if m.playerIndex ~= 0 then return end

    frameCounter = frameCounter + 1

    -- Sistema de sincronización tardía de semilla.
    -- Detecta cuando gGlobalSyncTable.seed cambia (ya sea por el host o por sync de red
    -- al unirse a una partida en curso) y re-aplica el shuffle y las texturas de pintura.
    local currentSeed = gGlobalSyncTable.seed
    if currentSeed and currentSeed > 0 and currentSeed ~= lastAppliedSeed then
        lastAppliedSeed = currentSeed
        apply_shuffle()
        set_painting_texture()
        -- Forzar re-randomización de objetos en el siguiente on_warp
        currLevel = 0
        currArea  = 0
    end

    -- Procesar cola de cinemáticas de estrella para clientes en red.
    -- Espera 20 frames para que el spawn_sync_object llegue antes de buscar la estrella.
    if #pendingStarCutscenes > 0 then
        for i = #pendingStarCutscenes, 1, -1 do
            local pending = pendingStarCutscenes[i]
            pending.timer = pending.timer - 1
            if pending.timer <= 0 then
                local nearestStar = nil
                local nearestDistSq = 1000000
                for_each_object_with_behavior(id_bhvSpawnedStar, function(star)
                    local dx = star.oPosX - pending.x
                    local dy = star.oPosY - pending.y
                    local dz = star.oPosZ - pending.z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq < nearestDistSq then
                        nearestDistSq = distSq
                        nearestStar = star
                    end
                end)
                if nearestStar then
                    cutscene_object(CUTSCENE_STAR_SPAWN, nearestStar)
                    cur_obj_play_sound_2(SOUND_GENERAL_STAR_APPEARS)
                end
                table.remove(pendingStarCutscenes, i)
            end
        end
    end

    prevent_peach_letter_cutscene(m)

    process_special_objects()

    if gGlobalSyncTable.showStarMarkers then
        for_each_object_with_behavior(id_bhvSpawnedStar, function(star)
            spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES,
                star.oPosX, star.oPosY + 50, star.oPosZ, nil)
        end)
    end

    if gGlobalSyncTable.starRequirement > 0 and
       gGlobalSyncTable.starRequirement > gMarioStates[0].numStars and
       gNetworkPlayers[0].currLevelNum == LEVEL_BITS then
        if not warp_to_castle(gPlayerSyncTable[0].entryLevel) then
            warp_to_level(LEVEL_CASTLE, 1, 0)
        end
        djui_chat_message_create("Necesitas " .. gGlobalSyncTable.starRequirement .. " estrellas")
    end

    if (m.controller.buttonDown & U_JPAD) ~= 0 then
        startHoldTimer = startHoldTimer + 1

        if startHoldTimer == 40 and network_is_server() then
            djui_chat_message_create("Mantén START 0.7 segundos más para regenerar...")
        end

        if startHoldTimer >= requiredHoldTime and not startRegenerated then
            if network_is_server() then
                local oldSeed = gGlobalSyncTable.seed

                sm64_random_advance(20)
                for i = 1, 10 do
                    accumulate_entropy()
                    sm64_random_advance(2)
                end

                local newSeed = generate_seed(oldSeed)

                sm64_random_seed(newSeed & 0xFFFF)
                sm64_random_advance(8)

                gGlobalSyncTable.randomizeLvl = true
                gGlobalSyncTable.randomizeObj = true
                gGlobalSyncTable.seed = newSeed
                lastAppliedSeed = newSeed  -- Evitar doble apply en el detector de semilla
                apply_shuffle()
                set_painting_texture()

                local special = check_special_seed(newSeed)
                if special and special.effect then
                    special.effect()
                end

                djui_chat_message_create("====================")
                djui_chat_message_create("ANTERIOR: " .. oldSeed)
                djui_chat_message_create("ACTUAL: " .. gGlobalSyncTable.seed)
                djui_chat_message_create("====================")

                -- Resetear estado de nivel para que on_warp fuerce re-randomización aunque ya estemos en el castillo
                currLevel = 0
                currArea  = 0
                warp_to_level(LEVEL_CASTLE_GROUNDS, 1, 0)

                network_send(true, {id = PACKET_SEED_CHANGE, seed = newSeed})
                spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES, m.pos.x, m.pos.y + 150, m.pos.z, nil)
            else
                djui_chat_message_create("Solo el host puede regenerar")
            end

            startRegenerated = true
        end
    else
        startHoldTimer = 0
        startRegenerated = false
    end
end

-- =============================================================================
-- [026] - HOOKS DE NIVEL Y WARP
-- =============================================================================
local np0 = gNetworkPlayers[0]

local function apply_vibrant_colors()
    local r, g, b = get_vibrant_color()
    
    set_skybox_color(0, r)
    set_skybox_color(1, g)
    set_skybox_color(2, b)
    
    set_fog_color(0, math.floor(r * 0.8))
    set_fog_color(1, math.floor(g * 0.8))
    set_fog_color(2, math.floor(b * 0.8))
end

local function on_warp()
    -- Cuando warpeamos a un nivel (no al castillo), limpiamos el flag justExited
    if np0.currLevelNum ~= LEVEL_CASTLE and 
       np0.currLevelNum ~= LEVEL_CASTLE_GROUNDS and 
       np0.currLevelNum ~= LEVEL_CASTLE_COURTYARD then
        gPlayerSyncTable[0].justExited = false
    end

    if currLevel ~= np0.currLevelNum or currArea ~= np0.currAreaIndex then
        currArea = np0.currAreaIndex
        currLevel = np0.currLevelNum

        for_each_object_with_behavior(id_bhvWhompKingBoss, whomp_init)
        for_each_object_with_behavior(id_bhvSmallWhomp, whomp_init)
        for_each_object_with_behavior(id_bhvTreasureChestBottom, treasure_chest_bottom)
        for_each_object_with_behavior(id_bhvTreasureChestTop, treasure_chest_top)
        for_each_object_with_behavior(id_bhvWarpPipe, invis_pipe)

        if gGlobalSyncTable.randomizeObj then
            blorandomseed(gGlobalSyncTable.seed)
            randomize_all_objects()
        end
        
        apply_vibrant_colors()
    end
end

local function level_init()
    if gGlobalSyncTable.randomizeLvl then
        if np0.currLevelNum == LEVEL_BITFS or np0.currLevelNum == LEVEL_BITS then
            if gGlobalSyncTable.starRequirement > 0 and
               gGlobalSyncTable.starRequirement > gMarioStates[0].numStars then
                if not warp_to_castle(gPlayerSyncTable[0].entryLevel or LEVEL_CASTLE) then
                    warp_to_level(LEVEL_CASTLE, 1, 0)
                end
                djui_chat_message_create("Necesitas " .. gGlobalSyncTable.starRequirement .. " estrellas")
                return
            end
        end
    end

    apply_vibrant_colors()
    set_override_skybox(get_random_skybox())

    -- Si acabamos de salir del nivel, NO redirigir de vuelta
    if gPlayerSyncTable[0].justExited then
        -- Limpiamos el flag para futuras entradas
        gPlayerSyncTable[0].justExited = false
    end

    if levelTable[np0.currCourseNum] and gGlobalSyncTable.randomizeLvl then
        if gPlayerSyncTable[0].entryLevel == nil then
            gPlayerSyncTable[0].entryLevel = np0.currLevelNum
            gPlayerSyncTable[0].entryCourse = np0.currCourseNum
        end
        if not levelsToSkip[np0.currLevelNum] then
            local newLevel = levelTable[np0.currCourseNum]
            -- Solo redirigir si estamos en el nivel VANILLA de la pintura (el entryLevel)
            -- Y NO acabamos de salir del nivel (justExited)
            if not gPlayerSyncTable[0].justExited and 
               np0.currLevelNum == gPlayerSyncTable[0].entryLevel and 
               newLevel ~= np0.currLevelNum then
                warp_to_level(newLevel, 1, np0.currActNum)
            end
            if musicTable and #musicTable > 0 then
                set_background_music(0, musicTable[blorandom(1, #musicTable)], 0)
            end
        end
    else
        -- Llegamos al castillo/exterior o a un nivel fuera de la tabla de shuffle.
        local inCastle = np0.currLevelNum == LEVEL_CASTLE or
                         np0.currLevelNum == LEVEL_CASTLE_GROUNDS or
                         np0.currLevelNum == LEVEL_CASTLE_COURTYARD
        if inCastle or not gGlobalSyncTable.randomizeLvl then
            -- Si hay un reposicionamiento pendiente (el jugador murió en un nivel redirigido),
            -- redirigir ahora al spawn correcto de la pintura. Hacemos esto AQUÍ (en level_init
            -- del castillo) en lugar de on_death para evitar conflictos con el warp vanilla.
            if castleRepositionPending and inCastle and gGlobalSyncTable.randomizeLvl then
                local targetLevel = castleRepositionPending
                castleRepositionPending = nil
                gPlayerSyncTable[0].entryLevel = nil
                gPlayerSyncTable[0].entryCourse = nil
                warp_to_castle(targetLevel)
                return  -- El engine hará otro HOOK_ON_LEVEL_INIT con la posición correcta
            end
            gPlayerSyncTable[0].entryLevel = nil
            gPlayerSyncTable[0].entryCourse = nil
        end
    end

    on_warp()
end

-- =============================================================================
-- [027] - EVENTOS DE MUERTE Y PAUSA
-- =============================================================================
local START_BUTTON = 0x1000

local function prevent_peach_letter_cutscene(m)
    if m.action == 0x13000400 then
        if m.usedObj and get_id_from_behavior(m.usedObj.behavior) == id_bhvPeachLetter then
            set_mario_action(m, ACT_IDLE, 0)

            if m.usedObj and m.usedObj.oBehParams then
                spawn_star_with_cutscene(m.pos.x, m.pos.y + 300, m.pos.z, m.usedObj.oBehParams)
            end

            djui_chat_message_create("\\#00FF00\\¡Carta de Peach omitida!")
            return true
        end
    end
    return false
end

local function on_death(m)
    -- Si la randomización NO está activa, no hacemos nada especial
    if not gGlobalSyncTable.randomizeLvl then
        return
    end
    
    -- Verificamos si estamos en un nivel redirigido (tenemos entryLevel guardado)
    if gPlayerSyncTable[0].entryLevel then
        local myLevel = gNetworkPlayers[0].currLevelNum
        local myArea = gNetworkPlayers[0].currAreaIndex
        local companionPresent = false
        
        -- Verificamos si hay otros jugadores en el mismo nivel
        for i = 1, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected and
               gNetworkPlayers[i].currLevelNum == myLevel and
               gNetworkPlayers[i].currAreaIndex == myArea then
                companionPresent = true
                break
            end
        end
        
        -- Si NO hay compañeros, podemos controlar el warp
        if not companionPresent then
            -- Obtenemos el preset actual
            local preset = gGlobalSyncTable.difficultyPreset or "normal"
            
            -- Presets difíciles: reaparecer en el mismo nivel (en su posición vanilla)
            if preset == "infierno" or preset == "apocalipsis" then
                -- Dejamos que el engine maneje la muerte normalmente
                -- El jugador reaparecerá en el nivel actual
                return
            else
                -- Presets fáciles/normales: warpear a la pintura original
                -- Esto SOBRESCRIBE el warp del engine
                warp_to_castle(gPlayerSyncTable[0].entryLevel)
                return
            end
        else
            -- Hay compañeros: el engine coop los convierte en burbuja
            -- No hacemos nada, el coop maneja esto automáticamente
            return
        end
    end
end

local function on_pause_exit(toCastle)
    -- Solo nos interesa cuando salimos AL CASTILLO
    if not toCastle then return end
    
    -- Si la randomización NO está activa, no hacemos nada
    if not gGlobalSyncTable.randomizeLvl then return end
    
    -- Verificamos si estamos en un nivel redirigido
    if gPlayerSyncTable[0].entryLevel then
        local preset = gGlobalSyncTable.difficultyPreset or "normal"
        
        -- Presets difíciles: salir al castillo normalmente
        if preset == "infierno" or preset == "apocalipsis" then
            -- El warp normal de pausa ya nos llevará al castillo
            -- Marcamos que acabamos de salir para evitar el re-warp en level_init
            gPlayerSyncTable[0].justExited = true
            return
        else
            -- Presets fáciles/normales: warpear DIRECTAMENTE a la pintura original
            warp_to_castle(gPlayerSyncTable[0].entryLevel)
            
            -- Marcamos que acabamos de salir para evitar re-warp en level_init
            gPlayerSyncTable[0].justExited = true
            return
        end
    end
end

-- =============================================================================
-- [028] - SISTEMA DE RED
-- =============================================================================
local function on_seed_change(data)
    if not data.seed or data.seed <= 0 then return end

    currArea = 0
    currLevel = 0
    gPlayerSyncTable[0].entryLevel = nil
    gPlayerSyncTable[0].entryCourse = nil

    -- Actualizar semilla y shuffle ANTES del warp para que level_init use los valores correctos
    gGlobalSyncTable.seed = data.seed
    lastAppliedSeed = data.seed  -- Evitar doble apply en el detector de semilla
    apply_shuffle()
    set_painting_texture()

    sm64_random_seed(data.seed & 0xFFFF)
    sm64_random_advance(8)

    gMarioStates[0].health = 0x880

    -- Forzar warp al jardín del castillo para que todos los jugadores recarguen objetos
    warp_to_level(LEVEL_CASTLE_GROUNDS, 1, 0)

    local special = check_special_seed(data.seed)
    if special then
        djui_popup_create(special.message, 2)
    end
end

local function on_menu_toggle(data)
    if network_is_server() then
        gGlobalSyncTable[data.var] = data.value
    end
end

local function on_menu_scroll(data)
    if network_is_server() then
        gGlobalSyncTable[data.var] = data.value
    end
end

local function on_preset_change(data)
    if network_is_server() then
        apply_preset(data.preset)
    end
end

-- Clientes en red reciben este paquete cuando el servidor spawnea una estrella.
-- Se encola en pendingStarCutscenes para reproducir el cutscene cuando el objeto
-- sincronizado haya llegado (unos pocos frames de margen).
local function on_star_spawn_packet(data)
    local myLevel = gNetworkPlayers[0].currLevelNum
    local myArea  = gNetworkPlayers[0].currAreaIndex
    if myLevel == data.level and myArea == data.area then
        table.insert(pendingStarCutscenes, {
            x = data.x, y = data.y, z = data.z, timer = 20
        })
    end
end

local sPacketTable = {
    [PACKET_SEED_CHANGE]  = on_seed_change,
    [PACKET_MENU_TOGGLE]  = on_menu_toggle,
    [PACKET_MENU_SCROLL]  = on_menu_scroll,
    [PACKET_PRESET_CHANGE] = on_preset_change,
    [PACKET_STAR_SPAWN]   = on_star_spawn_packet,
}

function network_send_include_self(reliable, data)
    network_send(reliable, data)
    if sPacketTable[data.id] then
        sPacketTable[data.id](data)
    end
end

local function on_packet_receive(data)
    if sPacketTable[data.id] then
        sPacketTable[data.id](data)
    end
end

-- =============================================================================
-- [029] - COMANDOS DE CHAT
-- =============================================================================
local function seed_command(msg)
    local seed = tonumber(msg)
    if not seed then
        djui_chat_message_create("\\#FF5555\\❌ Uso: /seed [número]")
        return true
    end

    seed = math.max(1, math.min(seed, 0x7FFFFFFE))
    local oldSeed = gGlobalSyncTable.seed

    if seed == oldSeed then
        djui_chat_message_create("\\#FFAA00\\⚠️ La semilla ya es " .. seed)
        return true
    end

    if not network_is_server() then
        djui_chat_message_create("\\#FF5555\\❌ Solo el host puede cambiar la semilla")
        return true
    end

    djui_chat_message_create("====================")
    djui_chat_message_create("ANTERIOR: " .. oldSeed)
    djui_chat_message_create("ACTUAL: " .. seed)
    djui_chat_message_create("====================")

    sm64_random_advance(12)
    sm64_random_seed(seed & 0xFFFF)
    network_send_include_self(true, {id = PACKET_SEED_CHANGE, seed = seed})

    local m = gMarioStates[0]
    if m then
        spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES,
            m.pos.x, m.pos.y + 150, m.pos.z, nil)
    end

    return true
end

local function where_command(msg)
    local m = gMarioStates[0]
    if not m then return true end

    local star, dist, secondStar, secondDist = find_and_highlight_nearest_star(m)

    if star then
        djui_chat_message_create(string.format("\\#FFD700\\🌟 ESTRELLA MÁS CERCANA: %.0f unidades", dist))
        djui_chat_message_create(string.format("\\#FFFFFF\\Posición: X=%.0f Y=%.0f Z=%.0f",
            star.oPosX, star.oPosY, star.oPosZ))

        -- Spawn de un objeto ancla temporal en la posición de la estrella.
        -- Reproduce CUTSCENE_STAR_SPAWN y se auto-destruye a los ~5 segundos,
        -- devolviendo la cámara a Mario automáticamente (sin quedar fija como antes).
        if id_bhvWhereCameraAnchor then
            spawn_non_sync_object(id_bhvWhereCameraAnchor, E_MODEL_NONE,
                star.oPosX, star.oPosY, star.oPosZ, nil)
        end
        cur_obj_play_sound_2(SOUND_GENERAL_STAR_APPEARS)

        for i = 1, 8 do
            local angle = (i / 8) * math.pi * 2
            local offsetX = math.cos(angle) * 100
            local offsetZ = math.sin(angle) * 100
            spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES,
                star.oPosX + offsetX,
                star.oPosY + 50,
                star.oPosZ + offsetZ,
                nil)
        end

        local dx = star.oPosX - m.pos.x
        local dz = star.oPosZ - m.pos.z
        local angle = math.atan2(dz, dx) * 180 / math.pi
        local direction = ""

        if angle >= -22.5 and angle < 22.5 then direction = "ESTE →"
        elseif angle >= 22.5 and angle < 67.5 then direction = "NORESTE ↗"
        elseif angle >= 67.5 and angle < 112.5 then direction = "NORTE ↑"
        elseif angle >= 112.5 and angle < 157.5 then direction = "NOROESTE ↖"
        elseif angle >= 157.5 or angle < -157.5 then direction = "OESTE ←"
        elseif angle >= -157.5 and angle < -112.5 then direction = "SUROESTE ↙"
        elseif angle >= -112.5 and angle < -67.5 then direction = "SUR ↓"
        elseif angle >= -67.5 and angle < -22.5 then direction = "SURESTE ↘"
        end

        djui_chat_message_create(string.format("\\#AAAAAA\\Dirección: %s", direction))

        if secondStar and secondDist < 5000 then
            djui_chat_message_create(string.format("\\#DDDDDD\\(También hay otra estrella a %.0f unidades)", secondDist))
            spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES,
                secondStar.oPosX, secondStar.oPosY + 50, secondStar.oPosZ, nil)
        end
    else
        djui_chat_message_create("\\#FF5555\\❌ No hay estrellas en este nivel")

        local spawner = obj_get_first_with_behavior_id(id_bhvStarSpawnCoordinates)
        if spawner then
            djui_chat_message_create("💫 Hay un spawner de estrella en:")
            djui_chat_message_create(string.format("X=%.0f Y=%.0f Z=%.0f",
                spawner.oPosX, spawner.oPosY, spawner.oPosZ))

            spawn_non_sync_object(id_bhvSparkleSpawn, E_MODEL_SPARKLES,
                spawner.oPosX, spawner.oPosY + 100, spawner.oPosZ, nil)
        end
    end

    return true
end

local function raycast_command(msg)
    local redSuccessRate = 0
    if raycastStats.redCoins.attempts > 0 then
        redSuccessRate = (raycastStats.redCoins.successes / (raycastStats.redCoins.successes + raycastStats.redCoins.fallbacks)) * 100
    end

    local starSuccessRate = 0
    if raycastStats.stars.attempts > 0 then
        starSuccessRate = (raycastStats.stars.successes / (raycastStats.stars.successes + raycastStats.stars.fallbacks)) * 100
    end

    local totalSuccessRate = 0
    if raycastStats.totalAttempts > 0 then
        totalSuccessRate = (raycastStats.totalSuccesses / (raycastStats.totalSuccesses + raycastStats.totalFallbacks)) * 100
    end

    djui_chat_message_create("====================")
    djui_chat_message_create("📊 ESTADÍSTICAS RAYCAST")
    djui_chat_message_create("====================")
    djui_chat_message_create(string.format("MONEDAS ROJAS: %d intentos | %.1f%% calidad | %d fallbacks",
        raycastStats.redCoins.attempts, redSuccessRate, raycastStats.redCoins.fallbacks))
    djui_chat_message_create(string.format("ESTRELLAS: %d intentos | %.1f%% calidad | %d fallbacks",
        raycastStats.stars.attempts, starSuccessRate, raycastStats.stars.fallbacks))
    djui_chat_message_create("--------------------")
    djui_chat_message_create(string.format("TOTAL: %d intentos | %.1f%% éxito | %d fallbacks",
        raycastStats.totalAttempts, totalSuccessRate, raycastStats.totalFallbacks))
    djui_chat_message_create("====================")

    return true
end

local function preset_command(msg)
    if not network_is_server() then
        djui_chat_message_create("Solo el host puede cambiar el preset")
        return true
    end

    if msg == "casual" or msg == "normal" or msg == "chaos" or msg == "infierno" or msg == "apocalipsis" then
        network_send_include_self(true, {id = PACKET_PRESET_CHANGE, preset = msg})
        djui_chat_message_create("Preset cambiado a: " .. presets[msg].name)
    else
        djui_chat_message_create("Presets: casual, normal, chaos, infierno, apocalipsis")
    end
    return true
end

local function markers_command(msg)
    if msg == "on" then
        gGlobalSyncTable.showStarMarkers = true
        djui_chat_message_create("Marcadores de estrellas ACTIVADOS")
    elseif msg == "off" then
        gGlobalSyncTable.showStarMarkers = false
        djui_chat_message_create("Marcadores de estrellas DESACTIVADOS")
    else
        djui_chat_message_create("Uso: /markers on/off")
    end
    return true
end

local function showstats_command(msg)
    if msg == "on" then
        gGlobalSyncTable.showStats = true
        djui_chat_message_create("📊 Estadísticas MOSTRADAS en HUD")
    elseif msg == "off" then
        gGlobalSyncTable.showStats = false
        djui_chat_message_create("📊 Estadísticas OCULTADAS")
    else
        djui_chat_message_create("Uso: /showstats on/off")
    end
    return true
end

local function reset_command(msg)
    if not network_is_server() then
        djui_chat_message_create("Solo el host puede reiniciar")
        return true
    end

    djui_chat_message_create("🔄 REINICIANDO RANDOMIZER...")

    apply_shuffle()
    set_painting_texture()

    if gPlayerSyncTable[0].entryLevel then
        if not warp_to_castle(gPlayerSyncTable[0].entryLevel) then
            warp_to_level(gPlayerSyncTable[0].entryLevel, 1, 0)
        end
    else
        warp_to_level(gLevelValues.entryLevel, 1, 0)
    end

    djui_chat_message_create("✅ Randomizer reiniciado con semilla " .. gGlobalSyncTable.seed)

    return true
end

local function help_command(msg)
    djui_chat_message_create("=== COMANDOS RANDOMIZER ===")
    djui_chat_message_create("/seed [número] - Cambiar semilla")
    djui_chat_message_create("/where - Mostrar estrella más cercana (con animación)")
    djui_chat_message_create("/raycast - Mostrar estadísticas de raycast")
    djui_chat_message_create("/preset casual/normal/chaos/infierno/apocalipsis")
    djui_chat_message_create("/markers on/off - Marcadores de estrellas")
    djui_chat_message_create("/showstats on/off - Estadísticas en HUD")
    djui_chat_message_create("/reset - Reiniciar randomizer con misma semilla")
    djui_chat_message_create("/menu - Abrir menú")
    djui_chat_message_create("Mantener START para regenerar")
    return true
end

-- =============================================================================
-- [030] - CARGA DE MODS
-- =============================================================================
local function on_mods_loaded()
    if not modsLoadedFlag then
        gPlayerSyncTable[0].entryLevel = nil
        gPlayerSyncTable[0].entryCourse = nil
        -- La semilla puede no estar sincronizada todavía en este punto.
        -- El detector de semilla en mario_update aplicará el shuffle cuando llegue.
        local currentSeed = gGlobalSyncTable.seed
        if currentSeed and currentSeed > 0 then
            lastAppliedSeed = currentSeed
        end
        apply_shuffle()
        set_painting_texture()
        modsLoadedFlag = true
        -- Si ya hay randomización activa el jugador se unió en partida iniciada:
        -- forzar warp al jardín del castillo para que cargue todos los objetos randomizados
        if gGlobalSyncTable.randomizeLvl or gGlobalSyncTable.randomizeObj then
            warp_to_level(LEVEL_CASTLE_GROUNDS, 1, 0)
        end
    end

    if currHack == "vanilla" then
        set_painting_texture()
    end
end

-- =============================================================================
-- [031] - HUD CON ESTADÍSTICAS VISIBLES
-- =============================================================================
local function on_hud_render_behind()
    djui_hud_set_resolution(RESOLUTION_N64)

    local sWidth = djui_hud_get_screen_width()
    local sHeight = djui_hud_get_screen_height()

    if not djui_is_playerlist_open() then return end

    djui_hud_set_font(FONT_TINY)

    local scale = 0.4
    local lineHeight = 14 * scale
    local boxPadding = 4

    local maxWidth = 0
    local playerCount = 0

    for i = 0, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected then
            local nameWidth = djui_hud_measure_text(gNetworkPlayers[i].name) * scale
            local levelWidth = djui_hud_measure_text("Entry Level: " .. (get_level_name(gPlayerSyncTable[i].entryCourse or 0, gPlayerSyncTable[i].entryLevel or 0, 1) or "Castle")) * scale
            maxWidth = math.max(maxWidth, nameWidth, levelWidth)
            playerCount = playerCount + 1
        end
    end

    local x = 30
    local y = 50
    local boxWidth = maxWidth + (boxPadding * 2)
    local boxHeight = (playerCount * (lineHeight * 2)) + (boxPadding * 2)

    djui_hud_set_color(0, 0, 0, 150)
    djui_hud_render_rect(x - boxPadding, y - boxPadding, boxWidth, boxHeight)

    djui_hud_set_color(255, 255, 255, 255)
    for i = 0, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected then
            djui_hud_print_text(gNetworkPlayers[i].name, x, y, scale)
            djui_hud_print_text("Entry Level: "..(get_level_name(gPlayerSyncTable[i].entryCourse or 0, gPlayerSyncTable[i].entryLevel or 0, 1) or "Castle"), x, y + lineHeight, scale)
            y = y + (lineHeight * 2)
        end
    end

    djui_hud_set_font(FONT_HUD)

    local seedText = "SEED "..gGlobalSyncTable.seed
    djui_hud_print_text(seedText, ((sWidth - djui_hud_measure_text(seedText)) * 0.5), 16, 1)

    local presetName = presets[gGlobalSyncTable.difficultyPreset or "normal"].name
    djui_hud_print_text(presetName, sWidth - djui_hud_measure_text(presetName) - 10, 16, 0.5)

    if gGlobalSyncTable.showStats then
        djui_hud_set_font(FONT_TINY)
        djui_hud_set_color(255, 255, 0, 255)
        
        local redTotal = raycastStats.redCoins.successes + raycastStats.redCoins.fallbacks
        local redRate = (redTotal > 0) and (raycastStats.redCoins.successes / redTotal * 100) or 0
        
        local starTotal = raycastStats.stars.successes + raycastStats.stars.fallbacks
        local starRate = (starTotal > 0) and (raycastStats.stars.successes / starTotal * 100) or 0
        
        local totalRate = (raycastStats.totalAttempts > 0) and 
            (raycastStats.totalSuccesses / (raycastStats.totalSuccesses + raycastStats.totalFallbacks) * 100) or 0
        
        local statsX = sWidth - 250
        local statsY = sHeight - 120
        
        djui_hud_print_text("📊 RAYCAST STATS", statsX, statsY, 0.45)
        djui_hud_print_text(string.format("ROJAS: %d (%.1f%%)", raycastStats.redCoins.attempts, redRate), 
            statsX, statsY + 20, 0.4)
        djui_hud_print_text(string.format("ESTRELLAS: %d (%.1f%%)", raycastStats.stars.attempts, starRate), 
            statsX, statsY + 40, 0.4)
        djui_hud_print_text(string.format("TOTAL: %d (%.1f%%)", raycastStats.totalAttempts, totalRate), 
            statsX, statsY + 60, 0.4)
        djui_hud_print_text(string.format("FALLBACKS: %d", raycastStats.totalFallbacks), 
            statsX, statsY + 80, 0.4)
    end
end

-- =============================================================================
-- [032] - FUNCIONES EXPORTADAS
-- =============================================================================
local function get_randomized_level(course)
    return levelTable[course]
end

local function get_entry_level_from_local(playerIndex)
    return gPlayerSyncTable[playerIndex].entryLevel, gPlayerSyncTable[playerIndex].entryCourse
end

local function get_globalsynctable(str)
    return gGlobalSyncTable[str]
end

local function set_globalsynctable(str, x)
    gGlobalSyncTable[str] = x
end

local function send_packet(reliable, data)
    network_send_include_self(reliable, data)
end

_G.randomizer = {
    get_randomized_level_from_course = get_randomized_level,
    get_entry_level_from_local = get_entry_level_from_local,
    get_synctable = get_globalsynctable,
    set_synctable = set_globalsynctable,
    send_packet = send_packet,
    apply_preset = apply_preset,
}

-- =============================================================================
-- [033] - REGISTRO DE HOOKS
-- =============================================================================

-- Comportamiento temporal de anclaje de cámara para el comando /where.
-- Reproduce CUTSCENE_STAR_SPAWN y se auto-destruye a los ~5 segundos,
-- lo que termina el cutscene automáticamente sin quedar la cámara fija.
do
    local function where_anchor_init(o)
        cutscene_object(CUTSCENE_STAR_SPAWN, o)
    end
    local function where_anchor_loop(o)
        if o.oTimer > 150 then
            obj_mark_for_deletion(o)
        end
    end
    id_bhvWhereCameraAnchor = hook_behavior(nil, OBJ_LIST_DEFAULT, true,
        where_anchor_init, where_anchor_loop, "bhvRandomizerWhereCameraAnchor")
end

hook_event(HOOK_ON_SEQ_LOAD, seq_load)
hook_event(HOOK_MARIO_UPDATE, mario_update)
hook_event(HOOK_ON_LEVEL_INIT, level_init)
hook_event(HOOK_ON_WARP, on_warp)
hook_event(HOOK_ON_PAUSE_EXIT, on_pause_exit)
hook_event(HOOK_ON_DEATH, on_death)
hook_event(HOOK_UPDATE, accumulate_entropy)
hook_event(HOOK_ON_PACKET_RECEIVE, on_packet_receive)
hook_event(HOOK_ON_SYNC_VALID, on_mods_loaded)
hook_event(HOOK_ON_HUD_RENDER, on_hud_render_behind)

-- /where disponible para TODOS los jugadores (no solo el servidor).
hook_chat_command("where", "Mostrar estrella más cercana (con animación)", where_command)

if network_is_server() then
    hook_chat_command("seed", "[número] Cambiar semilla", seed_command)
    hook_chat_command("raycast", "Mostrar estadísticas de raycast", raycast_command)
    hook_chat_command("preset", "casual/normal/chaos/infierno/apocalipsis", preset_command)
    hook_chat_command("markers", "on/off - Mostrar marcadores", markers_command)
    hook_chat_command("showstats", "on/off - Mostrar estadísticas en HUD", showstats_command)
    hook_chat_command("reset", "Reiniciar randomizer", reset_command)
    hook_chat_command("help", "Mostrar ayuda", help_command)
end

hook_behavior(id_bhvStarSpawnCoordinates, OBJ_LIST_LEVEL, true, star_spawn_init, nil, "bhvRandomizerStarSpawnCoordinates")
