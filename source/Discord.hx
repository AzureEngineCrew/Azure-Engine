package;

#if DISCORD_RPC
import Sys.sleep;
import hxdiscord_rpc.Discord;
import hxdiscord_rpc.Types;
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
	static var presence:DiscordRichPresence = new DiscordRichPresence();

	public static function initialize()
	{
		var handlers:DiscordEventHandlers = new DiscordEventHandlers();
		handlers.ready = cpp.Function.fromStaticFunction(onReady);
		handlers.disconnected = cpp.Function.fromStaticFunction(onDisconnected);
		handlers.errored = cpp.Function.fromStaticFunction(onError);
		Discord.Initialize("863222024192262205", cpp.RawPointer.addressOf(handlers), false, null);

		sys.thread.Thread.create(() ->
		{
			while (true)
			{
				#if DISCORD_DISABLE_IO_THREAD
				Discord.UpdateConnection();
				#end
				Discord.RunCallbacks();
				sleep(2);
			}
		});

		trace("Discord Client initialized");
		isInitialized = true;
	}

	public static function shutdown()
	{
		Discord.Shutdown();
	}

	static function onReady(request:cpp.RawConstPointer<DiscordUser>):Void
	{
		presence.details = "In the Menus";
		presence.largeImageKey = "icon";
		presence.largeImageText = "Psych Engine";
		Discord.UpdatePresence(cpp.RawConstPointer.addressOf(presence));
	}

	static function onDisconnected(errorCode:Int, message:cpp.ConstCharStar):Void
	{
		trace('Discord: Disconnected ($errorCode:$message)');
	}

	static function onError(errorCode:Int, message:cpp.ConstCharStar):Void
	{
		trace('Discord: Error ($errorCode:$message)');
	}

	public static function changePresence(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float)
	{
		var startTimestamp:Float = if (hasStartTimestamp) Date.now().getTime() else 0;

		if (endTimestamp > 0)
			endTimestamp = startTimestamp + endTimestamp;

		presence.details = details;
		presence.state = state;
		presence.largeImageKey = "icon";
		presence.largeImageText = "Engine Version: " + MainMenuState.psychEngineVersion;
		presence.smallImageKey = smallImageKey;
		// Obtained times are in milliseconds so they are divided so Discord can use it
		presence.startTimestamp = Std.int(startTimestamp / 1000);
		presence.endTimestamp = Std.int(endTimestamp / 1000);

		Discord.UpdatePresence(cpp.RawConstPointer.addressOf(presence));
	}

	#if LUA_ALLOWED
	public static function addLuaCallbacks(lua:State) {
		Lua_helper.add_callback(lua, "changePresence", function(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float) {
			changePresence(details, state, smallImageKey, hasStartTimestamp, endTimestamp);
		});
	}
	#end
}
#else
class DiscordClient
{
	public static var isInitialized:Bool = false;

	public static function shutdown() {}

	public static function initialize() {}

	public static function changePresence(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float) {}

	#if LUA_ALLOWED
	public static function addLuaCallbacks(lua:State) {
		Lua_helper.add_callback(lua, "changePresence", function(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float) {});
	}
	#end
}
#end