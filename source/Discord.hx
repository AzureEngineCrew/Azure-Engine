package;

import flixel.util.typeLimit.OneOfTwo;
import haxe.Json;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

#if (flixel >= "5.3.0")
import flixel.sound.FlxSound;
#else
import flixel.system.FlxSound;
#end

#if DISCORD_RPC
import Sys.sleep;
import hxdiscord_rpc.Discord;
import hxdiscord_rpc.Types;
import lime.app.Application;
import sys.thread.Thread;
#end

#if LUA_ALLOWED
import llua.Lua;
import llua.State;
#end

using StringTools;

#if DISCORD_RPC
class DiscordClient
{
	public static var isInitialized:Bool = false;
	public static var ready:Bool = false;
	public static var clientID:String = null;
	public static var logoKey:String = null;
	public static var logoText:String = null;

	private static inline var defaultClientID:String = "1568640146793046076";
	private static inline var defaultLogoKey:String = "icon";
	private static inline var defaultLogotext:String = "Azure Engine";

	public static var discordThread:Thread = null;
	private static var stopThread:Bool = false;

	public static var user:DUser = null;
	public static var lastPresence:DPresence = null;
	
	public static var enabled:Bool = true;
	private static var pending:DPresence = null;
	private static var lastUpdate:Float = 0;
	private static inline var updateCooldown:Float = 15000; // ms
	private static var exitHooked:Bool = false;

	public static var events:DEvents = {};

	public static var songCovers:Dynamic = null;
	
	// consts
	public static var REPLY_NO:Int = 0;
	public static var REPLY_YES:Int = 1;
	public static var REPLY_IGNORE:Int = 2;
	public static var PARTY_PRIVATE:Int = 0;
	public static var PARTY_PUBLIC:Int = 1;

	public static function loadConfig()
	{
		var cfg:DConfig = null;
		var paths:Array<String> = [];
		
		#if MODS_ALLOWED
			paths.push(Paths.modFolders('data/discord.json'));
		#end
		paths.push(Paths.getPreloadPath('data/discord.json'));

		for (p in paths)
		{
			if (!FileSystem.exists(p))
				continue;
			try
			{
				cfg = Json.parse(File.getContent(p));
				trace('Discord: loaded config from $p');
				break;
			}
			catch (e:Dynamic)
			{
				trace('Discord: failed to parse $p ($e)');
			}
		}

		logoKey = (cfg != null && cfg.logoKey != null) ? cfg.logoKey : defaultLogoKey;
		logoText = (cfg != null && cfg.logoText != null) ? cfg.logoText : defaultLogotext;
		songCovers = (cfg != null) ? cfg.songCovers : null;

		setClientID((cfg != null && cfg.clientID != null) ? cfg.clientID : defaultClientID);	
	}

	public static function initialize()
	{
		if (isInitialized)
			return;

		loadConfig();

		isInitialized = true;

		startClient(clientID);

		if (discordThread == null)
		{
			discordThread = Thread.create(function()
			{
				while (true)
				{
					while (!stopThread)
					{
						#if DISCORD_DISABLE_IO_THREAD
						Discord.UpdateConnection();
						#end
						Discord.RunCallbacks();
						flushPending();

						sleep(2);
					}

					sleep(1); // to reduce cpu
				}
			});
		}

		if (!exitHooked)
		{
			exitHooked = true;
			Application.current.onExit.add(function(_) shutdown());
		}

		trace("Discord Daemon initialized");
	}

	public static function setClientID(id:String)
	{
		if (clientID == id)
			return;
		clientID = id;
		if (isInitialized)
		{
			Discord.Shutdown();
			ready = false;
			startClient(id);
		}
	}

	private static function startClient(id:String)
	{
		var handlers:DiscordEventHandlers = new DiscordEventHandlers();
		handlers.ready = cpp.Function.fromStaticFunction(onReady);
		handlers.disconnected = cpp.Function.fromStaticFunction(onDisconnected);
		handlers.errored = cpp.Function.fromStaticFunction(onError);
		handlers.joinGame = cpp.Function.fromStaticFunction(onJoin);
		handlers.joinRequest = cpp.Function.fromStaticFunction(onJoinReq);
		handlers.spectateGame = cpp.Function.fromStaticFunction(onSpectate);
		Discord.Initialize(id, cpp.RawPointer.addressOf(handlers), false, null);
		stopThread = false;
	}

	public static function shutdown()
	{
		if (!isInitialized)
			return;
		ready = false;
		stopThread = true;
		isInitialized = false;
		pending = null;
		Discord.Shutdown();
	}

	// presence

	public static function changePresence(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float, ?largeImageKey:String)
	{
		var startTimestamp:Float = (hasStartTimestamp == true) ? Date.now().getTime() : 0;

		if (endTimestamp != null && endTimestamp > 0)
			endTimestamp = startTimestamp + endTimestamp;
		else
			endTimestamp = 0;

		// Obtained times are in milliseconds so they are divided so Discord can use it
		changePresenceAdvanced({
			state: state,
			details: details,
			smallImageKey: smallImageKey,
			largeImageKey: largeImageKey,
			largeImageText: "Engine Version: " + MainMenuState.psychEngineVersion,
			startTimestamp: Std.int(startTimestamp / 1000),
			endTimestamp: Std.int(endTimestamp / 1000)
		});
	}

	public static function changeSongPresence(details:String, state:String, audio:FlxSound, ?smallImageKey:String)
	{
		var start:Float = 0;
		var end:Float = 0;

		if (audio != null && audio.playing)
		{
			start = Date.now().getTime();
			end = start + (audio.length - audio.time);
		}

		changePresenceAdvanced({
			state: state,
			details: details,
			smallImageKey: smallImageKey,
			startTimestamp: Std.int(start / 1000),
			endTimestamp: Std.int(end / 1000)
		});
	}

	public static function updateSongPresence(detailsText:String, song:String, diff:String, paused:Bool, ?icon:String, ?songLength:Float)
	{
		var state:String = song + " (" + diff + ")";

		var cover:String = null;
		if (songCovers != null)
			cover = Reflect.field(songCovers, Paths.formatToSongPath(song));

		if (paused || songLength == null)
			changePresence(detailsText, state, icon, null, null, cover);
		else
			changePresence(detailsText, state, icon, true, songLength, cover);
	}
	
	public static function changePresenceSince(details:String, state:String, ?smallImageKey:String, ?time:Float)
	{
		if (time == null)
			time = Date.now().getTime();

		changePresenceAdvanced({
			state: state,
			details: details,
			smallImageKey: smallImageKey,
			startTimestamp: Std.int(time / 1000)
		});
	}

	public static function changePresenceAdvanced(data:DPresence)
	{
		if (data == null || !enabled)
			return;

		if (data.largeImageKey == null)
			data.largeImageKey = logoKey;
		if (data.largeImageText == null)
			data.largeImageText = logoText;

		if (events.presenceUpdate != null && events.presenceUpdate(data) == false)
			return;

		lastPresence = data;

		// just to fix some ratelimiting bs man
		var now:Float = Date.now().getTime();
		if (now - lastUpdate < updateCooldown)
		{
			pending = data;
			return;
		}
		lastUpdate = now;
		pending = null;

		var dp:DiscordRichPresence = new DiscordRichPresence();
		if (data.state != null) dp.state = fixString(clamp(data.state, 128));
		if (data.details != null) dp.details = fixString(clamp(data.details, 128));
		if (data.startTimestamp != null) dp.startTimestamp = cast data.startTimestamp;
		if (data.endTimestamp != null) dp.endTimestamp = cast data.endTimestamp;
		if (data.largeImageKey != null) dp.largeImageKey = fixString(clamp(data.largeImageKey, 32));
		if (data.largeImageText != null) dp.largeImageText = fixString(clamp(data.largeImageText, 128));
		if (data.smallImageKey != null) dp.smallImageKey = fixString(clamp(data.smallImageKey, 32));
		if (data.smallImageText != null) dp.smallImageText = fixString(clamp(data.smallImageText, 128));
		if (data.partyId != null) dp.partyId = fixString(data.partyId);
		if (data.partySize != null) dp.partySize = data.partySize;
		if (data.partyMax != null) dp.partyMax = data.partyMax;
		if (data.partyPrivacy != null) dp.partyPrivacy = data.partyPrivacy;
		if (data.matchSecret != null) dp.matchSecret = fixString(data.matchSecret);
		if (data.joinSecret != null) dp.joinSecret = fixString(data.joinSecret);
		if (data.spectateSecret != null) dp.spectateSecret = fixString(data.spectateSecret);
		if (data.instance != null) dp.instance = cast data.instance;

		Discord.UpdatePresence(cpp.RawConstPointer.addressOf(dp));
	}

	public static function clearPresence()
	{
		pending = null;
		lastPresence = null;
		Discord.ClearPresence();
	}

	public static function setEnabled(value:Bool)
	{
		enabled = value;
		if (!value)
			clearPresence();
		else if (lastPresence != null)
			changePresenceAdvanced(lastPresence);
	}

	private static function flushPending()
	{
		if (pending != null && Date.now().getTime() - lastUpdate >= updateCooldown)
		{
			var p:DPresence = pending;
			pending = null;
			changePresenceAdvanced(p);
		}
	}

	public static function respond(userId:String, reply:Int)
	{
		Discord.Respond(fixString(userId), reply);
	}

	// helpers

	@:noCompletion public static function fixString(str:String)
	{
		return new cpp.ConstCharStar(cast(str, String));
	}

	@:noCompletion public static function toString(str:cpp.ConstCharStar)
	{
		return cast(str, String);
	}

	private static function clamp(s:String, maxBytes:Int):String
	{
		if (s == null) return null;
		if (haxe.io.Bytes.ofString(s).length <= maxBytes) return s;

		while (s.length > 0 && haxe.io.Bytes.ofString(s + "...").length > maxBytes)
			s = s.substr(0, s.length - 1);
		return s + "...";
	}

	private static function getUUID():String
	{
		var uuid = new StringBuf();
		for (i in 0...16)
			uuid.add(StringTools.hex(Math.floor(Math.random() * 16), 1));
		return uuid.toString();
	}

	// handler

	private static function onReady(request:cpp.RawConstPointer<DiscordUser>):Void
	{
		user = DUser.initRaw(request);
		ready = true;

		trace('Discord: Connected to user ${user.globalName} (${user.handle})');

		if (lastPresence != null)
			changePresenceAdvanced(lastPresence);
		else
			changePresence("In the Menus", null);
		
		if (events.ready != null)
			events.ready(user);
	}

	private static function onDisconnected(errorCode:Int, message:cpp.ConstCharStar):Void
	{
		ready = false;
		var finalMsg:String = cast(message, String);
		trace('Discord: Disconnected ($errorCode: $finalMsg)');

		if (events.disconnected != null)
			events.disconnected(errorCode, finalMsg);
	}

	private static function onError(errorCode:Int, message:cpp.ConstCharStar):Void
	{
		ready = false;
		var finalMsg:String = cast(message, String);
		trace('Discord: Error ($errorCode: $finalMsg)');

		if (events.errored != null)
			events.errored(errorCode, finalMsg);
	}

	private static function onJoin(joinSecret:cpp.ConstCharStar):Void
	{
		trace("Discord: Someone has just joined");

		if (events.joinGame != null)
			events.joinGame(cast(joinSecret, String));
	}

	private static function onSpectate(spectateSecret:cpp.ConstCharStar):Void
	{
		trace("Discord: Someone started spectating your game");

		if (events.spectateGame != null)
			events.spectateGame(cast(spectateSecret, String));
	}

	private static function onJoinReq(request:cpp.RawConstPointer<DiscordUser>):Void
	{
		trace("Discord: Someone has just requested to join");

		if (events.joinRequest != null)
			events.joinRequest(DUser.initRaw(request));
	}

	#if LUA_ALLOWED
	public static function addLuaCallbacks(lua:State)
	{
		Lua_helper.add_callback(lua, "changePresence", function(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float) {
			changePresence(details, state, smallImageKey, hasStartTimestamp, endTimestamp);
		});

		Lua_helper.add_callback(lua, "clearPresence", function() {
			clearPresence();
		});

		Lua_helper.add_callback(lua, "changePresenceAdvanced", function(t:Dynamic) {
			if (t == null) return;
			changePresenceAdvanced({
				state: Reflect.field(t, "state"),
				details: Reflect.field(t, "details"),
				largeImageKey: Reflect.field(t, "largeImageKey"),
				largeImageText: Reflect.field(t, "largeImageText"),
				smallImageKey: Reflect.field(t, "smallImageKey"),
				smallImageText: Reflect.field(t, "smallImageText")
			});
		});

		Lua_helper.add_callback(lua, "discordReady", function() return ready);

		Lua_helper.add_callback(lua, "getDiscordUsername", function() {
			return (user != null) ? user.globalName : "";
		});
	}
	#end
}
#else
class DiscordClient
{
	public static var isInitialized:Bool = false;
	public static var ready:Bool = false;
	public static var clientID:String = null;
	public static var logoKey:String = null;
	public static var logoText:String = null;
	public static var user:DUser = null;
	public static var lastPresence:DPresence = null;
	public static var events:DEvents = {};
	
	public static function loadConfig() {}
	public static function initialize() {}
	public static function shutdown() {}
	public static function setClientID(id:String) {}

	public static var songCovers:Dynamic = null;
	public static function changePresence(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float, ?largeImageKey:String) {}
	public static function changeSongPresence(details:String, state:String, audio:FlxSound, ?smallImageKey:String) {}
	public static function changePresenceSince(details:String, state:String, ?smallImageKey:String, ?time:Float) {}
	public static function changePresenceAdvanced(data:DPresence) {}
	public static function clearPresence() {}
	public static function respond(userId:String, reply:Int) {}

	// some stubs to prevent crashing
	public static var enabled:Bool = false;
	public static function setEnabled(value:Bool) {}
	public static function updateSongPresence(detailsText:String, song:String, diff:String, paused:Bool, ?icon:String, ?songLength:Float) {}

	#if LUA_ALLOWED
	public static function addLuaCallbacks(lua:State)
	{
		Lua_helper.add_callback(lua, "changePresence", function(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float) {});
		Lua_helper.add_callback(lua, "clearPresence", function() {});
		Lua_helper.add_callback(lua, "changePresenceAdvanced", function(t:Dynamic) {});
		Lua_helper.add_callback(lua, "discordReady", function() return false);
		Lua_helper.add_callback(lua, "getDiscordUsername", function() return "");
	}
	#end
}
#end

final class DUser
{
	/** The username + discriminator if they have it **/
	public var handle:String;

	/** The user id, aka 860561967383445535 **/
	public var userId:String;

	/** The user's username **/
	public var username:String;

	/** The #number from before Discord changed to usernames only, 0 if the user has a username **/
	public var discriminator:Int;

	/** The user's avatar filename **/
	public var avatar:String;

	/** The user's display name **/
	public var globalName:String;

	/** If the user is a bot or not **/
	public var bot:Bool;

	/** Check the Discord docs for what these are **/
	public var flags:Int;

	/** If the user has nitro **/
	public var premiumType:NitroType;

	private function new() {}
	
	public function getAvatarUrl():String
	{
		if (avatar == null || avatar == "")
			return null;
		return 'https://cdn.discordapp.com/avatars/$userId/$avatar.png';
	}

	#if DISCORD_RPC
	public static function initRaw(req:cpp.RawConstPointer<DiscordUser>)
	{
		return init(cpp.ConstPointer.fromRaw(req).ptr);
	}

	public static function init(userData:cpp.Star<DiscordUser>)
	{
		var d = new DUser();
		d.userId = userData.userId;
		d.username = userData.username;
		d.discriminator = Std.parseInt(userData.discriminator);
		d.avatar = userData.avatar;
		d.globalName = userData.globalName;
		d.bot = userData.bot;
		d.premiumType = cast userData.premiumType;

		if (d.discriminator != 0)
			d.handle = '${d.username}#${d.discriminator}';
		else
			d.handle = '${d.username}';
		return d;
	}
	#end
}

enum abstract NitroType(Int) to Int from Int
{
	var NONE = 0;
	var NITRO_CLASSIC = 1;
	var NITRO = 2;
	var NITRO_BASIC = 3;
}

typedef DPresence =
{
	var ?state:String; /* max 128 bytes */
	var ?details:String; /* max 128 bytes */
	var ?startTimestamp:OneOfTwo<Int, haxe.Int64>;
	var ?endTimestamp:OneOfTwo<Int, haxe.Int64>;
	var ?largeImageKey:String; /* max 32 bytes */
	var ?largeImageText:String; /* max 128 bytes */
	var ?smallImageKey:String; /* max 32 bytes */
	var ?smallImageText:String; /* max 128 bytes */
	var ?partyId:String; /* max 128 bytes */
	var ?partySize:Int;
	var ?partyMax:Int;
	var ?partyPrivacy:Int;
	var ?matchSecret:String; /* max 128 bytes */
	var ?joinSecret:String; /* max 128 bytes */
	var ?spectateSecret:String; /* max 128 bytes */
	var ?instance:#if cpp OneOfTwo<Int, cpp.Int8> #else Int #end;
}

typedef DConfig =
{
	var ?clientID:String;
	var ?logoKey:String;
	var ?logoText:String;
	var ?songCovers:Dynamic;
}

typedef DEvents =
{
	var ?ready:DUser->Void;
	var ?disconnected:(errorCode:Int, message:String) -> Void;
	var ?errored:(errorCode:Int, message:String) -> Void;
	var ?joinGame:String->Void;
	var ?spectateGame:String->Void;
	var ?joinRequest:DUser->Void;
	var ?presenceUpdate:DPresence->Bool;
}