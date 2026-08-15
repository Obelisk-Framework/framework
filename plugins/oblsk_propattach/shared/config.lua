PropAttachConfig = {}

-- Permission key gating the /attach-point-edit placement tool.
PropAttachConfig.EditPermission = 'propattach_edit'

-- Fixed nudge steps used by the placement tool's arrow-key controls.
PropAttachConfig.OffsetStep = 0.01
PropAttachConfig.RotationStep = 1.0

-- Seconds to poll NetworkGetEntityFromNetworkId for a parent entity to
-- exist locally before giving up on an attach-create event, matching
-- EntityStreamerService.spawnObject's model-load timeout convention.
PropAttachConfig.ParentResolveTimeoutMs = 5000

-- Candidate bone names the placement tool sweeps via
-- GetEntityBoneIndexByName to find the nearest bone to a raycast hit.
-- Two lists since ped skeletons and vehicle bone sets don't overlap;
-- 'object' targets have no meaningful bones (attach at bone_index 0xFFFF /
-- root only).
PropAttachConfig.PedBoneNames = {
    'SKEL_Head', 'SKEL_Neck_1', 'SKEL_Spine3', 'SKEL_Spine2', 'SKEL_Spine1',
    'SKEL_Spine0', 'SKEL_Pelvis', 'SKEL_L_UpperArm', 'SKEL_L_Forearm',
    'SKEL_L_Hand', 'SKEL_R_UpperArm', 'SKEL_R_Forearm', 'SKEL_R_Hand',
    'SKEL_L_Thigh', 'SKEL_L_Calf', 'SKEL_L_Foot', 'SKEL_R_Thigh',
    'SKEL_R_Calf', 'SKEL_R_Foot',
}

PropAttachConfig.VehicleBoneNames = {
    'boot', 'bonnet', 'chassis', 'chassis_dummy', 'engine',
    'door_dside_f', 'door_dside_r', 'door_pside_f', 'door_pside_r',
    'bumper_f', 'bumper_r', 'roof',
}

return PropAttachConfig
