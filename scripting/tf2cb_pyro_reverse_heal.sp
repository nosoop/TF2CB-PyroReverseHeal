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

#define PLUGIN_VERSION "0.0.0"
public Plugin myinfo = {
    name = "[TF2CB] Reverse-Healer Pyro",
    author = "nosoop",
    description = "Implementation of 'Pyro, the Reverse Healer' reddit submission",
    version = PLUGIN_VERSION,
    url = "https://redd.it/428shq"
}

// Afterburn, by default, inflicts damage every 0.5 seconds for 10 seconds
// TODO is there any other way to detect this?  Preferably 
#define NUM_AFTERBURN_DAMAGE_TICKS 20
#define AFTERBURN_DAMAGE 3.0

#define DEFINDEX_WEAPON_BURN_DMG_REDUCED 72

// Damage bits taken from Advanced Weaponiser
// see: https://forums.alliedmods.net/showpost.php?p=2258564&postcount=7
#define TF_DMG_FIRE DMG_PLASMA
#define TF_DMG_AFTERBURN DMG_PREVENT_PHYSICS_FORCE | DMG_BURN

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
	
	// igniteplayer input does not fire onignited output, so we'll do that ourselves
	OnPlayerIgnited(client);
	
	return Plugin_Handled;
}

public Action AdminCmd_IgniteFriendlies(int client, int argc) {
	TFTeam clientTeam = TF2_GetClientTeam(client);
	for (int i = MaxClients; i > 0; --i) {
		if (IsClientInGame(i) && TF2_GetClientTeam(i) == clientTeam && i != client) {
			TF2_IgnitePlayer(i, client);
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
	}
}

public void OnClientPutInServer(int client) {
	SDKHook(client, SDKHook_OnTakeDamageAlive, SDKHook_OnTakeFireDamage);
	SDKHook(client, SDKHook_PreThink, SDKHook_OnClientPreThink);
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

public void TF2_OnConditionRemoved(int client, TFCond condition) {
	if (condition == TFCond_OnFire) {
		m_nAfterburnTicksRemaining[client] = 0;
	}
}

void OnPlayerIgnited(int client, int weapon = -1) {
	m_nAfterburnTicksRemaining[client] = NUM_AFTERBURN_DAMAGE_TICKS;
	m_flAfterburnDamage[client] = GetAfterburnDamage(weapon);
}

public void SDKHook_OnClientPreThink(int client) {
	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	
	// TODO only check on medigun
	if (IsValidEntity(activeWeapon) && HasEntProp(activeWeapon, Prop_Send, "m_bHealing")) {
		OnMedigunThink(client, activeWeapon);
	}
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
		AcceptEntityInput(player, "ExtinguishPlayer");
		
		AcceptEntityInput(healthkit, "Disable");
		
		// default health kit spawn time?
		CreateTimer(10.0, Timer_EnableHealthKit, healthkit, TIMER_FLAG_NO_MAPCHANGE);
		
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
 * Medigun variables
 */
int m_hHealingTarget[MAXPLAYERS+1];
bool m_bHealingTargetBurning[MAXPLAYERS+1];

/**
 * Processed while Medigun is active.
 * 
 * If the healing target changes between burning and not burning,
 * the medigun has its attributes changed so it has a 100% heal rate penalty,
 * and is forced to retarget.
 */
void OnMedigunThink(int client, int medigun) {
	if (GetEntProp(medigun, Prop_Send, "m_bHealing")) {
		int hPreviousHealTarget = m_hHealingTarget[client];
		m_hHealingTarget[client] = GetEntPropEnt(medigun, Prop_Send, "m_hHealingTarget");
		
		int hHealTarget = m_hHealingTarget[client];
		
		bool bTargetChanged = hPreviousHealTarget != m_hHealingTarget[client];
		
		if (bTargetChanged) {
			// PrintToChat(client, "healing %N", hHealTarget);
		}
		
		bool bWasHealingTargetBurning = m_bHealingTargetBurning[client];
		m_bHealingTargetBurning[client] = IsPlayerBurning(hHealTarget);
		
		bool bTargetBurnStateChanged = bWasHealingTargetBurning != m_bHealingTargetBurning[client];
		
		// Heal target changed state
		if (bTargetChanged || bTargetBurnStateChanged) {
			if (IsPlayerBurning(hHealTarget)) {
				// Player is burning -- apply heal rate penalty
				TF2Attrib_SetByName(medigun, "heal rate penalty", 0.0);
			} else {
				TF2Attrib_RemoveByName(medigun, "heal rate penalty");
			}
			
			// Attribute won't apply until the medigun is retargeted...
			
			// Player should be retargeted on next frame
			// TODO retarget during OnThinkPost
			// there is a bug where a player will disconnect from medibeam but continue healing if ignited while healing
			SetEntProp(medigun, Prop_Send, "m_bAttacking", false);
			SetEntProp(medigun, Prop_Send, "m_bHealing", false);
			SetEntPropEnt(medigun, Prop_Send, "m_hHealingTarget", -1);
		}
		
		// TODO reduce afterburn time based on damage
		// TODO bugfix where players ignited while healing continue to heal
	} else {
		m_hHealingTarget[client] = -1;
		m_bHealingTargetBurning[client] = false;
		
		TF2Attrib_RemoveByName(medigun, "heal rate penalty");
	}
}

/* Utility functions */

bool IsPlayer(int entity) {
	return (entity > 0 && entity <= MaxClients);
}

bool IsPlayerBurning(int player) {
	return TF2_IsPlayerInCondition(player, TFCond_OnFire);
}

float GetAfterburnDamage(int weapon = -1) {
	// on a scale of 1 to buried how slow is this
	float flAfterburnFactor = 1.0;
	
	if (IsValidEntity(weapon)) {
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
	}
	// TODO is afterburn hardcoded?
	return AFTERBURN_DAMAGE * flAfterburnFactor;
}