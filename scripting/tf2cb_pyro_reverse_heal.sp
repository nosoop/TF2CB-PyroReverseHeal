/**
 * todo desc it's 9:20a what the fuck am I doing awake working on this
 */
#pragma semicolon 1
#include <sourcemod>

#include <sdkhooks>
#include <sdktools>

#include <tf2_stocks>
#include <tf2attributes>

#pragma newdecls required

#define PLUGIN_VERSION "0.1.1"
public Plugin myinfo = {
    name = "[TF2CB] Reverse-Healer Pyro",
    author = "nosoop",
    description = "Implementation of 'Pyro, the Reverse Healer' reddit submission",
    version = PLUGIN_VERSION,
    url = "https://redd.it/428shq"
}

/**
 * Afterburn, by default, inflicts damage every 0.5 seconds (one tick) for 10
 * seconds.  They also inflict 3 points of damage per tick.
 * 
 * TODO is there any other way to detect these values?
 */
#define NUM_AFTERBURN_DAMAGE_TICKS 20
#define AFTERBURN_DAMAGE 3.0

/**
 * Attribute defindex for "weapon burn damage reduced" (afterburn damage modifier)
 */
#define DEFINDEX_WEAPON_BURN_DMG_REDUCED 72

// Damage bits from Advanced Weaponiser
// see: https://forums.alliedmods.net/showpost.php?p=2258564&postcount=7
#define TF_DMG_FIRE DMG_PLASMA
#define TF_DMG_AFTERBURN DMG_PREVENT_PHYSICS_FORCE | DMG_BURN

// See function IsHealerPenaltyOnBurningPlayers
bool g_bHealerPenaltyOnBurningPlayers = false;

// number of ticks of afterburn damage remaining
int m_nAfterburnTicksRemaining[MAXPLAYERS+1];

// amount of afterburn damage / tick the player is taking
float m_flAfterburnDamage[MAXPLAYERS+1];

public void OnPluginStart() {
	HookEvent("player_spawn", Event_OnPlayerSpawn);
	
	RegAdminCmd("sm_igniteme", AdminCmd_IgniteMe, ADMFLAG_ROOT, "Ignites the user.");
	RegAdminCmd("sm_ignitefriendlies", AdminCmd_IgniteFriendlies, ADMFLAG_ROOT, "Ignites the user's teammates.");
	
	for (int i = MaxClients; i > 0; --i) {
		if (IsClientInGame(i)) {
			OnClientPutInServer(i);
		}
	}
	
	HookExistingHealthKits();
}

public Action AdminCmd_IgniteMe(int client, int argc) {
	// World ignites for testing
	TF2_IgnitePlayer(client, client);
	
	// igniteplayer input does not fire onignited output, so we'll do that for ourselves
	OnPlayerIgnited(client);
	
	return Plugin_Handled;
}

public Action AdminCmd_IgniteFriendlies(int client, int argc) {
	// medigun testing
	TFTeam clientTeam = TF2_GetClientTeam(client);
	for (int i = MaxClients; i > 0; --i) {
		if (IsClientInGame(i) && TF2_GetClientTeam(i) == clientTeam && i != client) {
			TF2_IgnitePlayer(i, i);
			OnPlayerIgnited(i);
		}
	}
	return Plugin_Handled;
}

void HookExistingHealthKits() {
	char HEALTHKIT_CLASSNAMES[][] = {
		"item_healthkit_full",
		"item_healthkit_medium",
		"item_healthkit_small"
	};
	
	int healthkit = -1;
	
	for (int i = 0; i < sizeof(HEALTHKIT_CLASSNAMES); i++) {
		while (( healthkit = FindEntityByClassname(healthkit, HEALTHKIT_CLASSNAMES[i]) ) != -1) {
			HookHealthKit(healthkit);
		}
	}
}

// Hook healthpacks to block its healing
public void OnEntityCreated(int entity, const char[] classname) {
	if (StrContains(classname, "item_healthkit_") == 0) {
		HookHealthKit(entity);
	} else if (StrEqual(classname, "tf_projectile_healing_bolt")) {
		HookHealingBolt(entity);
	}
}

public void OnClientPutInServer(int client) {
	SDKHook(client, SDKHook_OnTakeDamageAlive, SDKHook_OnTakeFireDamage);
	SDKHook(client, SDKHook_PreThink, SDKHook_OnPreThinkCheckHealth);
}

public void Event_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	m_nAfterburnTicksRemaining[client] = 0;
}

public Action SDKHook_OnTakeFireDamage(int victim, int &attacker, int &inflictor,
		float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3]) {
	// TODO on extended sessions of burning, victim burns once more than expected.  how to fix???
	if (damagetype & TF_DMG_FIRE) {
		OnPlayerIgnited(victim, weapon);
	} 
	if (damagetype & TF_DMG_AFTERBURN && m_nAfterburnTicksRemaining[victim] > 0) {
		// for now we pretend the client wasn't still burning if less than 0
		m_nAfterburnTicksRemaining[victim]--;
	}
	return Plugin_Continue;
}

public void TF2_OnConditionAdded(int client, TFCond condition) {
	if (condition == TFCond_OnFire) {
		if (IsHealerPenaltyOnBurningPlayers()) {
			SetPreventHealersOnClient(client, false);
		}
	}
}

public void TF2_OnConditionRemoved(int client, TFCond condition) {
	if (condition == TFCond_OnFire) {
		m_nAfterburnTicksRemaining[client] = 0;
		
		if (IsHealerPenaltyOnBurningPlayers()) {
			SetPreventHealersOnClient(client, true);
		}
	}
}

void OnPlayerIgnited(int client, int weapon = -1) {
	m_nAfterburnTicksRemaining[client] = NUM_AFTERBURN_DAMAGE_TICKS;
	m_flAfterburnDamage[client] = GetAfterburnDamage(weapon);
}

/* Handle heal sources */

void HookHealthKit(int healthkit) {
	SDKHook(healthkit, SDKHook_Touch, OnHealthKitTouch);
}

/**
 * Custom handling of health kits:
 * If a burning player uses one, they are extinguished but not healed.
 * 
 * Touch event is (int hookedEntity, int other)
 */
public Action OnHealthKitTouch(int healthkit, int player) {
	if (IsPlayer(player) && IsPlayerBurning(player)) {
		TF2_ExtinguishPlayer(player);
		
		if ( GetEntPropEnt(healthkit, Prop_Data, "m_hOwnerEntity") != -1 ) {
			// Don't let it respawn if owned by valid entity (e.g., player's Sandvich)
			// We can't check bAutoMaterialize, as Sandviches also have that as `true`
			AcceptEntityInput(healthkit, "Kill");
		} else {
			// Owner is -1.  Assume it's a map healthkit; disable and respawn.
			AcceptEntityInput(healthkit, "Disable");	
			CreateTimer(10.0, Timer_EnableHealthKit, healthkit, TIMER_FLAG_NO_MAPCHANGE);
		}
		
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

/**
 * Handles custom health kit respawning when picked up by a burning player.
 */
public Action Timer_EnableHealthKit(Handle timer, int healthkit) {
	if (IsValidEntity(healthkit)) {
		AcceptEntityInput(healthkit, "Enable");
		EmitGameSoundToAll("Item.Materialize", healthkit);
	}
	return Plugin_Handled;
}

/**
 * Prevent healing on client, but still allow medigun to target them.
 */
stock void SetPreventHealersOnClient(int client, bool bEnabled) {
	if (bEnabled) {
		TF2Attrib_RemoveByName(client, "health from healers reduced");
	} else {
		TF2Attrib_SetByName(client, "health from healers reduced", 0.0);
	}
}

/**
 * Hook Crusader's Crossbow touch event.
 */
void HookHealingBolt(int healbolt) {
	SDKHook(healbolt, SDKHook_Touch, OnHealingBoltTouch);
}

/** 
 * If a Crusader's Crossbow bolt touches a friendly player, then they are immediately
 * extinguished.
 */
public Action OnHealingBoltTouch(int healbolt, int recipient) {
	// TODO is there a way to calculate potential heal amount?
	if (IsPlayer(recipient) && IsPlayerBurning(recipient)) {
		int crossbow = GetEntPropEnt(healbolt, Prop_Send, "m_hLauncher");
		int healer = GetEntPropEnt(crossbow, Prop_Send, "m_hOwner");
		
		if (IsPlayer(healer) && TF2_GetClientTeam(healer) == TF2_GetClientTeam(recipient)) {
			TF2_ExtinguishPlayer(recipient);
			AcceptEntityInput(healbolt, "Kill");
		}
		
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

int m_iHealth[MAXPLAYERS+1];
int m_nAccumulatedBurnHealPoints[MAXPLAYERS+1];

/**
 * PreThink hook to check if the player has healed over the last tick.
 */
public void SDKHook_OnPreThinkCheckHealth(int client) {
	int m_iHealthLastTick = m_iHealth[client];
	m_iHealth[client] = GetClientHealth(client);
	
	if (IsPlayerBurning(client)) {
		int nHealPoints = m_iHealth[client] - m_iHealthLastTick;
		nHealPoints = nHealPoints > 0 ? nHealPoints : 0;
		
		// Prevent player healing, but save the amount healed.
		if (nHealPoints > 0) {
			SetEntityHealth(client, m_iHealthLastTick);
			m_nAccumulatedBurnHealPoints[client] += nHealPoints;
		}
		
		// Calculate how much afterburn damage is remaining.
		int nAfterburnDamageRemaining =
				RoundFloat(m_flAfterburnDamage[client] * m_nAfterburnTicksRemaining[client]);
		
		// Player is done burning if (stored heals > remaining afterburn)
		if (m_nAccumulatedBurnHealPoints[client] > nAfterburnDamageRemaining) {
			TF2_RemoveCondition(client, TFCond_OnFire);
			m_nAccumulatedBurnHealPoints[client] = 0;
		}
	} else {
		m_nAccumulatedBurnHealPoints[client] = 0;
	}
}

/* Configuration settings */

/**
 * Determines whether or not burning players are completely blocked from
 * healing on dispensers / mediguns.
 * 
 * While the behavior of shortening afterburn duration is much more accurate
 * when disabled, client-side prediction is also more screwy.
 */
bool IsHealerPenaltyOnBurningPlayers() {
	return g_bHealerPenaltyOnBurningPlayers;
}

/* Utility functions */

bool IsPlayer(int entity) {
	return (entity > 0 && entity <= MaxClients);
}

bool IsPlayerBurning(int player) {
	return TF2_IsPlayerInCondition(player, TFCond_OnFire);
}

/**
 * Input that extinguishes players (instead of just removing the burn condition).
 */
void TF2_ExtinguishPlayer(int player) {
	AcceptEntityInput(player, "ExtinguishPlayer");
}

/**
 * Returns the amount of afterburn damage.
 * 
 * If there are no modifier attributes on the weapon, the fire damage is
 * assumed to be AFTERBURN_DAMAGE (3.0, hardcoded).
 */
float GetAfterburnDamage(int weapon = -1) {
	float flAfterburnFactor = 1.0;
	
	if (IsValidEntity(weapon)) {
		// on a scale of 1 to slug how slow is it to read through tf2attribs every time
		// degreaser burn penalty is determined by static attribute
		int attribList[16];
		float valueList[16];
		
		int iDefIndex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
		int nStaticAttrs = TF2Attrib_GetStaticAttribs(iDefIndex, attribList, valueList);
		
		for (int i = 0; i < nStaticAttrs; i++) {
			switch (attribList[i]) {
				case DEFINDEX_WEAPON_BURN_DMG_REDUCED: {
					flAfterburnFactor = valueList[i];
				}
			}
		}
		
		// TODO also check other attribs in case of other plugin mods
	}
	
	// TODO is default afterburn hardcoded?
	return AFTERBURN_DAMAGE * flAfterburnFactor;
}