--[[
	RigAnimator (LocalScript)
	ONE file, fully client-sided. Works from StarterPlayerScripts, StarterCharacterScripts,
	StarterGui, etc. (no server script needed). Only the local player sees the animations.
	Works on R15 and R6. Every body part is posed by offsetting its Motor6D.C0.

	Includes:
	  - Procedural idle / walk / run / jump / fall / land animation
	  - Spawn animation (spin drop, slam, rise) with impact frames
	  - Death animation (hit, flail, fall, bounce, dissolve) with impact frames
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local lp = Players.LocalPlayer

local function setup(char)
if char:GetAttribute("RigAnimatorActive") then return end
char:SetAttribute("RigAnimatorActive", true)

local hum = char:WaitForChild("Humanoid", 15)
local hrp = char:WaitForChild("HumanoidRootPart", 15)
if not (hum and hrp) then return end
pcall(function() RunService:UnbindFromRenderStep("RigAnimator") end)
local isR15 = hum.RigType == Enum.HumanoidRigType.R15

local ACCENT = Color3.fromRGB(0, 200, 255)
local BLOOD = Color3.fromRGB(255, 50, 50)

local QUAD, BACK, BOUNCE = Enum.EasingStyle.Quad, Enum.EasingStyle.Back, Enum.EasingStyle.Bounce
local IN, OUT, INOUT = Enum.EasingDirection.In, Enum.EasingDirection.Out, Enum.EasingDirection.InOut

--------------------------------------------------------------------------------
-- Pose helpers (degrees). Rotation is applied in PARENT space around the joint.
-- Shoulder/hip +X = swing forward, Elbow +X = bend, Knee -X = bend,
-- Waist/Neck +X = lean/look back, Root +X = tilt backwards.
--------------------------------------------------------------------------------
local IDENT = CFrame.new()
local function R(rx, ry, rz, px, py, pz)
	return CFrame.new(px or 0, py or 0, pz or 0)
		* CFrame.Angles(math.rad(rx or 0), math.rad(ry or 0), math.rad(rz or 0))
end

--------------------------------------------------------------------------------
-- Joint discovery
--------------------------------------------------------------------------------
local MAP
if isR15 then
	MAP = {
		Root = { "LowerTorso", "Root" }, Waist = { "UpperTorso", "Waist" }, Neck = { "Head", "Neck" },
		RShoulder = { "RightUpperArm", "RightShoulder" }, RElbow = { "RightLowerArm", "RightElbow" }, RWrist = { "RightHand", "RightWrist" },
		LShoulder = { "LeftUpperArm", "LeftShoulder" }, LElbow = { "LeftLowerArm", "LeftElbow" }, LWrist = { "LeftHand", "LeftWrist" },
		RHip = { "RightUpperLeg", "RightHip" }, RKnee = { "RightLowerLeg", "RightKnee" }, RAnkle = { "RightFoot", "RightAnkle" },
		LHip = { "LeftUpperLeg", "LeftHip" }, LKnee = { "LeftLowerLeg", "LeftKnee" }, LAnkle = { "LeftFoot", "LeftAnkle" },
	}
else
	MAP = {
		Root = { "HumanoidRootPart", "RootJoint" }, Neck = { "Torso", "Neck" },
		RShoulder = { "Torso", "Right Shoulder" }, LShoulder = { "Torso", "Left Shoulder" },
		RHip = { "Torso", "Right Hip" }, LHip = { "Torso", "Left Hip" },
	}
end

local joints = {}
for name, info in pairs(MAP) do
	local part = char:WaitForChild(info[1], 5)
	local motor = part and part:WaitForChild(info[2], 5)
	if motor and motor:IsA("Motor6D") then
		local base = motor.C0
		joints[name] = {
			name = info[2], motor = motor, holder = motor.Parent,
			part0 = motor.Part0, part1 = motor.Part1, base = base, c1 = motor.C1,
			pos = base.Position, rot = base - base.Position,
		}
	end
end

-- The server breaks every joint when a character dies. Since this is fully
-- client-sided, we rebuild any joint that gets destroyed during death locally.
local dying = false
local function watchJoint(j)
	j.motor.AncestryChanged:Connect(function(_, parent)
		if parent == nil and (dying or hum.Health <= 0) and j.holder and j.holder.Parent then
			local m = Instance.new("Motor6D")
			m.Name = j.name
			m.Part0, m.Part1 = j.part0, j.part1
			m.C0, m.C1 = j.base, j.c1
			m.Parent = j.holder
			j.motor = m
			watchJoint(j)
		end
	end)
end
for _, j in pairs(joints) do watchJoint(j) end

local current = {}
for name in pairs(joints) do current[name] = IDENT end

local function blend(a, b, w)
	local out = {}
	for name in pairs(joints) do
		out[name] = (a[name] or IDENT):Lerp(b[name] or IDENT, w)
	end
	return out
end

local function applyJoints()
	for name, j in pairs(joints) do
		local off = current[name]
		j.motor.C0 = CFrame.new(j.pos + off.Position) * (off - off.Position) * j.rot
	end
end

--------------------------------------------------------------------------------
-- Kill default animations so they don't fight the CFrame poses
--------------------------------------------------------------------------------
local animate = char:FindFirstChild("Animate")
if animate then animate:Destroy() end
local animator = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
if animator then
	for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do tr:Stop(0) end
	-- remove this line if you want emotes / other Animations to still play
	animator.AnimationPlayed:Connect(function(tr) tr:Stop(0) end)
end

--------------------------------------------------------------------------------
-- Fade (local only)
--------------------------------------------------------------------------------
local fadeItems = {}
for _, d in ipairs(char:GetDescendants()) do
	if (d:IsA("BasePart") and d ~= hrp) or d:IsA("Decal") then
		table.insert(fadeItems, { d, d.Transparency })
	end
end
local function setVisible(v)
	for _, it in ipairs(fadeItems) do
		local inst, base = it[1], it[2]
		if inst.Parent then inst.Transparency = base + (1 - base) * (1 - v) end
	end
end

--------------------------------------------------------------------------------
-- Poses
--------------------------------------------------------------------------------
local K = isR15 and 1 or 0.35 -- R6 has no knees, so crouches are shallower
local P = {}

-- Spawn
P.SPAWN_AIR = {
	Root = R(-12, 0, 0, 0, 9, 0), Waist = R(8), Neck = R(-10),
	RShoulder = R(165, 0, 12), LShoulder = R(165, 0, -12),
	RElbow = R(15), LElbow = R(15),
	RHip = R(-18, 0, 5), LHip = R(-22, 0, -5),
	RKnee = R(-35), LKnee = R(-45), RAnkle = R(-20), LAnkle = R(-20),
}
P.SPAWN_DIVE = {
	Root = R(-8, 0, 0, 0, 0.3, 0), Waist = R(-4), Neck = R(10),
	RShoulder = R(-25, 0, 10), LShoulder = R(-25, 0, -10),
	RElbow = R(10), LElbow = R(10),
	RHip = R(-12, 0, 3), LHip = R(-12, 0, -3),
	RKnee = R(-12), LKnee = R(-12),
}
P.CROUCH = {
	Root = R(-8, 0, 0, 0, -1.0 * K, 0), Waist = R(-30), Neck = R(30),
	RShoulder = R(-30, 0, 38), LShoulder = R(-30, 0, -38),
	RElbow = R(35), LElbow = R(35),
	RHip = R(60 * K, 0, 5), LHip = R(60 * K, 0, -5),
	RKnee = R(-120), LKnee = R(-120), RAnkle = R(60), LAnkle = R(60),
}
P.RISE = {
	Root = R(4, 0, 0, 0, 0.12, 0), Waist = R(10), Neck = R(-8),
	RShoulder = R(10, 0, 18), LShoulder = R(10, 0, -18),
	RElbow = R(8), LElbow = R(8),
}

-- Death
P.DEATH_HIT = {
	Root = R(14, 0, 0, 0, 0.15, 0.7), Waist = R(22), Neck = R(30, 0, 12),
	RShoulder = R(-55, 0, 55), LShoulder = R(-35, 0, -65),
	RElbow = R(25), LElbow = R(40), RWrist = R(0, 0, 20), LWrist = R(0, 0, -20),
	RHip = R(22, 0, 4), LHip = R(-18, 0, -4),
	RKnee = R(-25), LKnee = R(-10), RAnkle = R(-10), LAnkle = R(15),
}
P.DEATH_FLAIL = {
	Root = R(38, 10, 0, 0, -0.6, 1.6), Waist = R(28, 0, -8), Neck = R(15, -20, 0),
	RShoulder = R(-110, 0, 30), LShoulder = R(-70, 0, -50),
	RElbow = R(60), LElbow = R(35), RWrist = R(0, 0, 25), LWrist = R(0, 0, -25),
	RHip = R(-35, 0, 10), LHip = R(-15, 0, -12),
	RKnee = R(-70), LKnee = R(-45), RAnkle = R(20), LAnkle = R(10),
}
P.DEATH_FALL = {
	Root = R(90, -8, 0, 0, -2.3, 2.4), Waist = R(-5), Neck = R(-8, 14, 0),
	RShoulder = R(10, 0, 60), LShoulder = R(25, 0, -50),
	RElbow = R(15), LElbow = R(30),
	RHip = R(-8, 0, 12), LHip = R(-3, 0, -14),
	RKnee = R(-14), LKnee = R(-6), RAnkle = R(10), LAnkle = R(5),
}
P.DEATH_BOUNCE = {
	Root = R(84, -8, 0, 0, -1.95, 2.45), Waist = R(6), Neck = R(10, 10, 0),
	RShoulder = R(-15, 0, 78), LShoulder = R(-5, 0, -70),
	RElbow = R(25), LElbow = R(40),
	RHip = R(-14, 0, 14), LHip = R(-10, 0, -16),
	RKnee = R(-22), LKnee = R(-14), RAnkle = R(15), LAnkle = R(10),
}
P.DEATH_REST = {
	Root = R(90, -8, 0, 0, -2.3, 2.4), Waist = R(-5), Neck = R(-12, 28, 6),
	RShoulder = R(18, 0, 48), LShoulder = R(30, 0, -42),
	RElbow = R(20), LElbow = R(35), RWrist = R(0, 0, 10), LWrist = R(0, 0, -10),
	RHip = R(-6, 0, 10), LHip = R(-2, 0, -12),
	RKnee = R(-10), LKnee = R(-4), RAnkle = R(8), LAnkle = R(4),
}

-- Air
P.AIR_UP = {
	Root = R(-6), Waist = R(-4), Neck = R(-6),
	RShoulder = R(140, 0, 20), LShoulder = R(140, 0, -20),
	RElbow = R(20), LElbow = R(20),
	RHip = R(10, 0, 2), LHip = R(-25, 0, -2),
	RKnee = R(-30), LKnee = R(-55), RAnkle = R(-10), LAnkle = R(15),
}
P.AIR_DOWN = {
	Root = R(-2), Neck = R(-8),
	RShoulder = R(30, 0, 75), LShoulder = R(30, 0, -75),
	RElbow = R(15), LElbow = R(15),
	RHip = R(-10, 0, 6), LHip = R(-5, 0, -6),
	RKnee = R(-25), LKnee = R(-18), RAnkle = R(10), LAnkle = R(10),
}

--------------------------------------------------------------------------------
-- Camera + screen FX
--------------------------------------------------------------------------------
local cam = workspace.CurrentCamera
local baseFov = cam.FieldOfView
local shake, punch = 0, 0
local holdFrames = 0

local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "RigImpactCC"
cc.Enabled = false
cc.Parent = Lighting

local hl = Instance.new("Highlight")
hl.Name = "RigImpactHL"
hl.Enabled = false
hl.Adornee = char
hl.FillTransparency = 0
hl.OutlineTransparency = 0
hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
hl.Parent = char

local function look(bright, contrast, tint, fill, outline)
	cc.Enabled = true
	cc.Brightness, cc.Contrast, cc.Saturation, cc.TintColor = bright, contrast, -1, tint
	if fill then
		hl.Enabled = true
		hl.FillColor, hl.OutlineColor = fill, outline
	else
		hl.Enabled = false
	end
end

local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
local LOOKS = {
	white = function() look(1, 0, WHITE, nil) end,                          -- flash
	ink   = function() look(0.25, 1, WHITE, BLACK, WHITE) end,              -- black silhouette, hard contrast
	dark  = function() look(-0.5, 1, WHITE, WHITE, WHITE) end,              -- white silhouette, dark world
	red   = function() look(-0.1, 0.6, BLOOD, BLOOD, WHITE) end,            -- red hit
}

-- Each entry is ONE rendered frame. Animation is frozen (hit-stop) while they play.
local function impactFrames(list)
	holdFrames = #list
	task.spawn(function()
		for _, name in ipairs(list) do
			LOOKS[name]()
			RunService.RenderStepped:Wait()
		end
		cc.Enabled = false
		hl.Enabled = false
	end)
end

local function groundPos()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -12, 0), rp)
	return hit and hit.Position or (hrp.Position - Vector3.new(0, 3, 0))
end

local function ring(color, size)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.Shape = Enum.PartType.Cylinder
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(0.25, 2, 2)
	p.CFrame = CFrame.new(groundPos() + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
	p.Parent = workspace
	TweenService:Create(p, TweenInfo.new(0.55, QUAD, OUT), { Size = Vector3.new(0.25, size, size), Transparency = 1 }):Play()
	Debris:AddItem(p, 0.7)
end

local function burst(color, count)
	local att = Instance.new("Attachment")
	att.Parent = hrp
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(color)
	pe.Lifetime = NumberRange.new(0.4, 0.9)
	pe.Speed = NumberRange.new(15, 35)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Drag = 4
	pe.LightEmission = 1
	pe.Rate = 0
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new(0, 1)
	pe.Parent = att
	pe:Emit(count)
	Debris:AddItem(att, 1.5)
end

--------------------------------------------------------------------------------
-- Keyframe sequence player
--------------------------------------------------------------------------------
local mode = "alive"
local seq

local function startSequence(frames, events, opts)
	opts = opts or {}
	local snap = {}
	local src = opts.startPose
	for name in pairs(joints) do
		snap[name] = src and (src[name] or IDENT) or current[name]
	end
	for _, ev in ipairs(events) do ev.done = false end
	seq = {
		frames = frames, events = events, snap = snap, clock = 0,
		duration = frames[#frames].t, onStep = opts.onStep, onDone = opts.onDone,
	}
end

local function sample(s)
	local prevT, prevPose = 0, s.snap
	for _, f in ipairs(s.frames) do
		if s.clock <= f.t then
			local a = (s.clock - prevT) / math.max(f.t - prevT, 1e-4)
			a = TweenService:GetValue(a, f.style or QUAD, f.dir or OUT)
			return blend(prevPose, f.pose, a)
		end
		prevT, prevPose = f.t, f.pose
	end
	return blend(prevPose, prevPose, 0)
end

--------------------------------------------------------------------------------
-- Procedural locomotion
--------------------------------------------------------------------------------
local phase, clock = 0, 0
local landT, landPower, lastVy, wasAir = 0, 0, 0, false

local function locomotion(dt)
	local vel = hrp.AssemblyLinearVelocity
	local lv = hrp.CFrame:VectorToObjectSpace(vel)
	local flat = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local fwd, side = -lv.Z, lv.X
	local amp = math.clamp(flat / 16, 0, 1.4)
	local dir = fwd < -1 and -1 or 1
	phase += dt * math.clamp(flat * 0.55, 0, 13) * dir
	clock += dt

	local s, c = math.sin(phase), math.cos(phase)
	local idle = 1 - math.clamp(amp * 2, 0, 1)
	local breathe = math.sin(clock * 1.8)
	local air = hum.FloorMaterial == Enum.Material.Air

	if air then lastVy = vel.Y end
	if wasAir and not air then
		landT = 0.25
		landPower = math.clamp(math.abs(lastVy) / 50, 0.2, 1)
	end
	wasAir = air

	local pose
	if air then
		pose = blend(P.AIR_UP, P.AIR_DOWN, math.clamp(-vel.Y / 40, 0, 1))
	else
		local rLeg, lLeg = s * 45 * amp, -s * 45 * amp
		local rKnee = -math.max(0, c) * 65 * amp - 6 * amp
		local lKnee = -math.max(0, -c) * 65 * amp - 6 * amp
		local rArm, lArm = -s * 55 * amp, s * 55 * amp
		pose = {
			Root = R(math.clamp(-fwd * 0.4, -10, 10), s * 5 * amp, math.clamp(-side * 0.4, -10, 10),
				0, -math.abs(c) * 0.12 * amp + breathe * 0.02 * idle, 0),
			Waist = R(breathe * 1.2 * idle, -s * 9 * amp, c * 2 * amp),
			Neck = R(math.clamp(fwd * 0.3, -6, 8) + breathe * 0.8 * idle, s * 5 * amp, 0),
			RShoulder = R(rArm, 0, 5 + breathe * 1.5 * idle), LShoulder = R(lArm, 0, -(5 + breathe * 1.5 * idle)),
			RElbow = R(6 * idle + (15 + math.max(0, rArm) * 0.8) * amp),
			LElbow = R(6 * idle + (15 + math.max(0, lArm) * 0.8) * amp),
			RHip = R(rLeg, 0, 2), LHip = R(lLeg, 0, -2),
			RKnee = R(rKnee), LKnee = R(lKnee),
			RAnkle = R(-(rLeg + rKnee) * 0.6), LAnkle = R(-(lLeg + lKnee) * 0.6),
		}
	end

	if landT > 0 then
		landT -= dt
		pose = blend(pose, P.CROUCH, math.clamp(landT / 0.25, 0, 1) * landPower * 0.85)
	end
	return pose
end

--------------------------------------------------------------------------------
-- Spawn
--------------------------------------------------------------------------------
local function playSpawn()
	mode = "spawn"
	setVisible(0)
	local ws, jp, jh = hum.WalkSpeed, hum.JumpPower, hum.JumpHeight
	hum.WalkSpeed, hum.JumpPower, hum.JumpHeight = 0, 0, 0

	local frames = {
		{ t = 0.12, pose = P.SPAWN_AIR },
		{ t = 0.42, pose = P.SPAWN_DIVE, style = QUAD, dir = IN },
		{ t = 0.52, pose = P.CROUCH, style = QUAD, dir = OUT },
		{ t = 0.95, pose = P.RISE, style = BACK, dir = OUT },
		{ t = 1.35, pose = {}, style = QUAD, dir = INOUT },
	}
	local events = {
		{ t = 0.42, fn = function()
			impactFrames({ "white", "ink", "dark" })
			shake, punch = 1.2, 10
			ring(ACCENT, 18)
			burst(ACCENT, 30)
		end },
	}
	startSequence(frames, events, {
		startPose = P.SPAWN_AIR,
		onStep = function(t)
			local v = math.clamp(t / 0.3, 0, 1)
			if v < 1 and math.random() < 0.4 then v *= 0.3 end -- glitchy materialize
			setVisible(v)
			if t < 0.42 and current.Root then -- spin during the drop
				local spin = math.rad(540) * (1 - t / 0.42) ^ 2
				current.Root = current.Root * CFrame.Angles(0, spin, 0)
			end
		end,
		onDone = function()
			mode = "alive"
			setVisible(1)
			hum.WalkSpeed, hum.JumpPower, hum.JumpHeight = ws, jp, jh
		end,
	})
end

--------------------------------------------------------------------------------
-- Death
--------------------------------------------------------------------------------
local function playDeath()
	if mode == "dead" then return end
	mode = "dead"
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hrp.Anchored = true -- keep the body where it died while joints do the falling

	local frames = {
		{ t = 0.09, pose = P.DEATH_HIT, style = QUAD, dir = OUT },
		{ t = 0.55, pose = P.DEATH_FLAIL, style = QUAD, dir = OUT },
		{ t = 1.05, pose = P.DEATH_FALL, style = QUAD, dir = IN },
		{ t = 1.20, pose = P.DEATH_BOUNCE, style = QUAD, dir = OUT },
		{ t = 1.45, pose = P.DEATH_REST, style = BOUNCE, dir = OUT },
		{ t = 2.40, pose = P.DEATH_REST },
	}
	local events = {
		{ t = 0, fn = function()
			impactFrames({ "white", "white", "ink", "dark", "red", "ink" })
			shake, punch = 3, -16
			burst(BLOOD, 40)
		end },
		{ t = 1.05, fn = function()
			impactFrames({ "ink" })
			shake, punch = 1.5, 4
			ring(BLOOD, 14)
		end },
		{ t = 1.70, fn = function() burst(ACCENT, 60) end },
	}
	startSequence(frames, events, {
		onStep = function(t) setVisible(1 - math.clamp((t - 1.7) / 0.6, 0, 1)) end,
	})
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local function step(dt)
	dt = math.min(dt, 1 / 20)

	-- camera FX (runs after the default camera so it doesn't accumulate)
	cam = workspace.CurrentCamera
	if cam then
		if shake > 0.002 then
			cam.CFrame *= CFrame.new((math.random() - 0.5) * shake, (math.random() - 0.5) * shake, 0)
				* CFrame.Angles(0, 0, math.rad((math.random() - 0.5) * shake * 4))
			shake *= math.exp(-dt * 9)
		end
		if punch ~= 0 then
			cam.FieldOfView = baseFov + punch
			punch *= math.exp(-dt * 7)
			if math.abs(punch) < 0.05 then punch = 0; cam.FieldOfView = baseFov end
		end
	end

	-- hit-stop: freeze the pose
	if holdFrames > 0 then
		holdFrames -= 1
		return
	end

	if mode == "alive" then
		local target = locomotion(dt)
		local a = 1 - math.exp(-dt * 16)
		for name in pairs(joints) do
			current[name] = current[name]:Lerp(target[name] or IDENT, a)
		end
	elseif seq then
		seq.clock += dt
		for _, ev in ipairs(seq.events) do
			if not ev.done and seq.clock >= ev.t then
				ev.done = true
				ev.fn()
			end
		end
		local pose = sample(seq)
		for name in pairs(joints) do current[name] = pose[name] or IDENT end
		if seq.onStep then seq.onStep(seq.clock) end
		if seq.clock >= seq.duration then
			local done = seq.onDone
			seq = nil
			if done then done() end
		end
	end

	applyJoints()
end

RunService:BindToRenderStep("RigAnimator", Enum.RenderPriority.Camera.Value + 1, step)

char.Destroying:Connect(function()
	RunService:UnbindFromRenderStep("RigAnimator")
	cc:Destroy()
	if cam then cam.FieldOfView = baseFov end
end)

hum.HealthChanged:Connect(function(h)
	if h <= 0 then dying = true; playDeath() end
end)
hum.Died:Connect(function()
	dying = true
	playDeath()
end)
playSpawn()
end -- setup

-- Works from anywhere (StarterCharacterScripts, StarterPlayerScripts, StarterGui...)
lp.CharacterAdded:Connect(setup)
if lp.Character then task.spawn(setup, lp.Character) end
