--!strict
local UserInputService = game:GetService("UserInputService")

local Signal = require(script.Parent.signal)
local Scythe = require(script.Parent.Scythe)

export type InputSignal = Signal.Signal<InputObject>

type InputMap = {
	[Enum.KeyCode | Enum.UserInputType]: {
		[boolean]: {
			[Enum.UserInputState]: InputSignal,
		},
	},
}

local DEFAULT_INPUT_STATE = Enum.UserInputState.Begin
local DEFAULT_GAME_PROCESSED = false

local signalInputMap: InputMap = {}
local listenerScope: Scythe.Scope? = nil

local function getInputSignal(
	input: Enum.KeyCode | Enum.UserInputType,
	state: Enum.UserInputState,
	gameProcessed: boolean
): InputSignal?
	local byGameProcessed = signalInputMap[input]
	if not byGameProcessed then
		return nil
	end

	local byState = byGameProcessed[gameProcessed]
	if not byState then
		return nil
	end

	return byState[state]
end

local function getOrCreateInputSignal(
	input: Enum.KeyCode | Enum.UserInputType,
	state: Enum.UserInputState,
	gameProcessed: boolean
): InputSignal
	if not signalInputMap[input] then
		signalInputMap[input] = {}
	end

	if not signalInputMap[input][gameProcessed] then
		signalInputMap[input][gameProcessed] = {}
	end

	if not signalInputMap[input][gameProcessed][state] then
		signalInputMap[input][gameProcessed][state] = (Signal.new() :: any) :: InputSignal
	end

	return signalInputMap[input][gameProcessed][state]
end

local function startListeningForInputs(): Scythe.Scope
	local function onInput(inputObject: InputObject, gameProcessed: boolean)
		local signal = getInputSignal(inputObject.KeyCode, inputObject.UserInputState, gameProcessed)

		if signal then
			signal:Fire(inputObject)
		end
	end

	local scope = Scythe.scope()

	Scythe.addBulk(
		scope,
		UserInputService.InputBegan:Connect(onInput),
		UserInputService.InputEnded:Connect(onInput)
	)

	return scope
end

local function createInput(
	input: Enum.KeyCode | Enum.UserInputType,
	state: Enum.UserInputState?,
	gameProcessed: boolean?
): InputSignal
	if listenerScope == nil then
		listenerScope = startListeningForInputs()
	end

	return getOrCreateInputSignal(
		input,
		state or DEFAULT_INPUT_STATE,
		if gameProcessed == nil then DEFAULT_GAME_PROCESSED else gameProcessed
	)
end

return createInput
