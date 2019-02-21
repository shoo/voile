/*******************************************************************************
 * ログ取得のためのユーティリティモジュール
 */
module voile.log;


import std.experimental.logger: Logger, FileLogger;

/*******************************************************************************
 * テキストファイルのロガー
 */
class TextFileLogger: FileLogger
{
	import std.experimental.logger: Logger, LogLevel, CreateFolder;
	import std.concurrency: Tid;
	import std.datetime: SysTime;
	import std.stdio: File;
	
	///
	this(in string fn, const LogLevel lv = LogLevel.all) @safe
	{
		this(fn, lv, CreateFolder.yes);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder) @safe
	{
		super(fn, lv, createFileNameFolder);
	}
	/// ditto
	this(File file, const LogLevel lv = LogLevel.all) @safe
	{
		super(file, lv);
	}
	///
	override protected void beginLogMsg(string file, int line, string funcName,
		string prettyFuncName, string moduleName, LogLevel logLevel,
		Tid threadId, SysTime timestamp, Logger logger)
		@safe
	{
		import std.experimental.logger: systimeToISOString;
		import std.string : lastIndexOf;
		import std.format: formattedWrite;
		//ptrdiff_t fnIdx = file.lastIndexOf('/') + 1;
		//ptrdiff_t funIdx = funcName.lastIndexOf('.') + 1;
		auto writer = this.file.lockingTextWriter();
		writer.formattedWrite("%s(%s): %s: %s @ ", file, line, logLevel, funcName);
		writer.systimeToISOString(timestamp);
		writer.put(": ");
	}
	
	///
	override protected void logMsgPart(scope const(char)[] msg)
	{
		import std.format: formattedWrite;
		formattedWrite(this.file.lockingTextWriter(), "%s", msg);
	}
	
	///
	override protected void finishLogMsg()
	{
		this.file.lockingTextWriter().put("\n");
		this.file.flush();
	}
}

/*******************************************************************************
 * JSONファイルのロガー
 */
class JsonFileLogger: Logger
{
private:
	import std.experimental.logger: Logger, LogLevel, CreateFolder;
	import std.concurrency: Tid;
	import std.datetime: SysTime;
	import std.stdio: File;
	File _file;
	string _filename;
public:
	///
	this(in string fn, const LogLevel lv = LogLevel.all) @safe
	{
		this(fn, lv, CreateFolder.yes);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder) @trusted
	{

		import std.file : exists, mkdirRecurse;
		import std.path : dirName;
		import std.conv : text;
		import core.stdc.stdio;
		super(lv);
		_filename = fn;
		if (createFileNameFolder)
		{
			auto d = dirName(_filename);
			mkdirRecurse(d);
			assert(exists(d), text("The folder the FileLogger should have",
			                       " created in '", d,"' could not be created."));
		}
		_file.open(_filename, _filename.exists ? "r+b": "w+b");
		_file.seek(0, SEEK_END);
		if (_file.tell() == 0)
		{
			_file.rawWrite("[]\n");
			_file.flush();
			_file.seek(-2, SEEK_END);
			_file.flush();
		}
		else
		{
			_file.seek(-3, SEEK_END);
		}
	}
	/// ditto
	this(File file, const LogLevel lv = LogLevel.all) @safe
	{
		super(lv);
		_file = file;
	}
	///
	override void writeLogMsg(ref LogEntry payload) @trusted
	{
		import std.format: formattedWrite;
		import std.json: JSONValue;
		import core.stdc.stdio;
		import std.stdio;
		_file.lock(LockType.readWrite);
		scope (exit)
			_file.unlock();
		char[1] buf;
		_file.rawRead(buf[]);
		auto writer = _file.lockingBinaryWriter();
		if (buf[0] != '\n')
		{
			_file.seek(-2, SEEK_END);
			writer.put("\n");
		}
		else
		{
			_file.seek(-3, SEEK_END);
			writer.put(",\n");
		}
		writer.formattedWrite(
			"{"
			~`"file":%s,`
			~`"line":"%s",`
			~`"funcName":"%s",`
			~`"prettyFuncName":%s,`
			~`"moduleName":"%s",`
			~`"logLevel":"%s",`
			~`"threadId":"%s",`
			~`"timestamp":"%s",`
			~`"msg":%s`
			~`}`~"\n]\n",
			JSONValue(payload.file).toString,
			payload.line,
			payload.funcName,
			JSONValue(payload.prettyFuncName).toString,
			payload.moduleName,
			payload.logLevel,
			payload.threadId,
			payload.timestamp.toISOExtString(),
			JSONValue(payload.msg).toString
		);
		_file.seek(-3, SEEK_END);
	}
	
	///
	string getFilename()
	{
		return _filename;
	}
}



/*******************************************************************************
 * XMLファイルのロガー
 */
class XmlFileLogger: Logger
{
private:
	import std.experimental.logger: Logger, LogLevel, CreateFolder;
	import std.concurrency: Tid;
	import std.datetime: SysTime;
	import std.stdio: File;
	File _file;
	string _filename;
public:
	///
	this(in string fn, const LogLevel lv = LogLevel.all) @safe
	{
		this(fn, lv, CreateFolder.yes);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder) @trusted
	{

		import std.file : exists, mkdirRecurse;
		import std.path : dirName;
		import std.conv : text;
		import core.stdc.stdio;
		super(lv);
		_filename = fn;
		if (createFileNameFolder)
		{
			auto d = dirName(_filename);
			mkdirRecurse(d);
			assert(exists(d), text("The folder the FileLogger should have",
			                       " created in '", d,"' could not be created."));
		}
		_file.open(_filename, _filename.exists ? "r+b": "w+b");
		_file.seek(0, SEEK_END);
		if (_file.tell() == 0)
		{
			_file.rawWrite("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<Log>\n</Log>\n");
			_file.flush();
			_file.seek(-7, SEEK_END);
			_file.flush();
		}
		else
		{
			_file.seek(-7, SEEK_END);
		}
	}
	/// ditto
	this(File file, const LogLevel lv = LogLevel.all) @safe
	{
		super(lv);
		_file = file;
	}
	///
	override void writeLogMsg(ref LogEntry payload) @trusted
	{
		import std.format: formattedWrite;
		import std.json: JSONValue;
		import core.stdc.stdio;
		import std.stdio;
		import std.xml: encode;
		auto writer = _file.lockingBinaryWriter();
		writer.formattedWrite(
			"<LogEntry"
			~` file="%s"`
			~` line="%s"`
			~` funcName="%s"`
			~` prettyFuncName="%s"`
			~` moduleName="%s"`
			~` logLevel="%s"`
			~` threadId="%s"`
			~` timestamp="%s"`
			~` msg="%s"`
			~" />\n</Log>\n",
			encode(payload.file),
			payload.line,
			payload.funcName,
			encode(payload.prettyFuncName),
			payload.moduleName,
			payload.logLevel,
			payload.threadId,
			payload.timestamp.toISOExtString(),
			encode(payload.file)
		);
		_file.seek(-7, SEEK_END);
	}
	
	///
	string getFilename()
	{
		return _filename;
	}
}


/*******************************************************************************
 * CSVファイルのロガー
 */
class CsvFileLogger: Logger
{
private:
	import std.experimental.logger: Logger, LogLevel, CreateFolder;
	import std.concurrency: Tid;
	import std.datetime: SysTime;
	import std.stdio: File;
	File _file;
	string _filename;
public:
	///
	this(in string fn, const LogLevel lv = LogLevel.all) @safe
	{
		this(fn, lv, CreateFolder.yes);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder) @trusted
	{

		import std.file : exists, mkdirRecurse;
		import std.path : dirName;
		import std.conv : text;
		import core.stdc.stdio;
		super(lv);
		_filename = fn;
		if (createFileNameFolder)
		{
			auto d = dirName(_filename);
			mkdirRecurse(d);
			assert(exists(d), text("The folder the FileLogger should have",
			                       " created in '", d,"' could not be created."));
		}
		_file.open(_filename, "a+b");
	}
	/// ditto
	this(File file, const LogLevel lv = LogLevel.all) @safe
	{
		super(lv);
		_file = file;
	}
	///
	override void writeLogMsg(ref LogEntry payload) @trusted
	{
		import std.format: formattedWrite;
		import std.json: JSONValue;
		import core.stdc.stdio;
		import std.stdio;
		auto writer = _file.lockingBinaryWriter();
		writer.formattedWrite(
			 `%s,`
			~`%s,`
			~`%s,`
			~`%s,`
			~`%s,`
			~`%s,`
			~`%s,`
			~`%s,`
			~`%s`
			~"\n",
			JSONValue(payload.file).toString,
			payload.line,
			payload.funcName,
			JSONValue(payload.prettyFuncName).toString,
			payload.moduleName,
			payload.logLevel,
			payload.threadId,
			payload.timestamp.toISOExtString(),
			JSONValue(payload.msg).toString
		);
	}
	
	///
	string getFilename()
	{
		return _filename;
	}
}

/*******************************************************************************
 * TSVファイルのロガー
 */
class TsvFileLogger: Logger
{
private:
	import std.experimental.logger: Logger, LogLevel, CreateFolder;
	import std.concurrency: Tid;
	import std.datetime: SysTime;
	import std.stdio: File;
	File _file;
	string _filename;
public:
	///
	this(in string fn, const LogLevel lv = LogLevel.all) @safe
	{
		this(fn, lv, CreateFolder.yes);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder) @trusted
	{

		import std.file : exists, mkdirRecurse;
		import std.path : dirName;
		import std.conv : text;
		import core.stdc.stdio;
		super(lv);
		_filename = fn;
		if (createFileNameFolder)
		{
			auto d = dirName(_filename);
			mkdirRecurse(d);
			assert(exists(d), text("The folder the FileLogger should have",
			                       " created in '", d,"' could not be created."));
		}
		_file.open(_filename, "a+b");
	}
	/// ditto
	this(File file, const LogLevel lv = LogLevel.all) @safe
	{
		super(lv);
		_file = file;
	}
	///
	override void writeLogMsg(ref LogEntry payload) @trusted
	{
		import std.format: formattedWrite;
		import std.json: JSONValue;
		import core.stdc.stdio;
		import std.stdio;
		auto writer = _file.lockingBinaryWriter();
		writer.formattedWrite(
			 "%s\t"
			~"%s\t"
			~"%s\t"
			~"\"%s\"\t"
			~"%s\t"
			~"%s\t"
			~"%s\t"
			~"%s\n",
			JSONValue(payload.file).toString,
			payload.line,
			payload.funcName,
			payload.prettyFuncName,
			payload.moduleName,
			payload.logLevel,
			payload.threadId,
			payload.timestamp.toISOExtString(),
			JSONValue(payload.msg).toString
		);
	}
	
	///
	string getFilename()
	{
		return _filename;
	}
}


/*******************************************************************************
 * クラス内で使用するロガーを切り替えるためのミックスインテンプレート
 */
mixin template Logging(loggerAlias...)
{
	private import std.experimental.logger: Logger, LogLevel;
	private import std.string: format;
	static if (loggerAlias.length == 1 && is(typeof(loggerAlias[0]): Logger))
	{
		private pragma(inline) typeof(loggerAlias[0]) logger() const
		{
			return cast()loggerAlias[0];
		}
	}
	else
	{
		private Logger _logger;
		private pragma(inline) Logger logger() const
		{
			return cast()_logger;
		}
	}
	private pragma(inline) void log(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const
	{
		static assert(Args.length != 0);
		static if (fmt is null)
		{
			static if (Args.length == 1)
			{
				logger.log!(Args[0])(logger.logLevel, args, line, file, funcName, prettyFuncName, moduleName);
			}
			else static if (is(Args[0]: const LogLevel))
			{
				logger.log!(Args[1])(args, line, file, funcName, prettyFuncName, moduleName);
			}
			else
			{
				logger.log!(line, file, funcName, prettyFuncName, moduleName)(logger.logLevel, args);
			}
		}
		else
		{
			static if (Args.length > 1 && is(Args[0]: const LogLevel))
			{
				logger.log!string(args[0], format!fmt(args[1..$]), line, file, funcName, prettyFuncName, moduleName);
			}
			else
			{
				logger.log!string(logger.logLevel, format!fmt(args), line, file, funcName, prettyFuncName, moduleName);
			}
			
		}
	}
	private pragma(inline) void trace(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const
	{
		static assert(Args.length != 0);
		static if (fmt is null)
		{
			static if (Args.length > 1)
			{
				logger.log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.trace, args);
			}
			else
			{
				logger.log!(Args[0])(LogLevel.trace, args, line, file, funcName, prettyFuncName, moduleName);
			}
		}
		else
		{
			logger.log!string(LogLevel.trace, format!fmt(args), line, file, funcName, prettyFuncName, moduleName);
		}
	}
	private pragma(inline) void info(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const
	{
		static assert(Args.length != 0);
		static if (fmt is null)
		{
			static if (Args.length > 1)
			{
				logger.log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.info, args);
			}
			else
			{
				logger.log!(Args[0])(LogLevel.info, args, line, file, funcName, prettyFuncName, moduleName);
			}
		}
		else
		{
			logger.log!string(LogLevel.info, format!fmt(args), line, file, funcName, prettyFuncName, moduleName);
		}
	}
	private pragma(inline) void warning(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const
	{
		static assert(Args.length != 0);
		static if (fmt is null)
		{
			static if (Args.length > 1)
			{
				logger.log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.warning, args);
			}
			else
			{
				logger.log!(Args[0])(LogLevel.warning, args, line, file, funcName, prettyFuncName, moduleName);
			}
		}
		else
		{
			logger.log!string(LogLevel.warning, format!fmt(args), line, file, funcName, prettyFuncName, moduleName);
		}
	}
	private pragma(inline) void error(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const
	{
		static assert(Args.length != 0);
		static if (fmt is null)
		{
			static if (Args.length > 1)
			{
				logger.log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.error, args);
			}
			else
			{
				logger.log!(Args[0])(LogLevel.error, args, line, file, funcName, prettyFuncName, moduleName);
			}
		}
		else
		{
			logger.log!string(LogLevel.error, format!fmt(args), line, file, funcName, prettyFuncName, moduleName);
		}
	}
	private pragma(inline) void fatal(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const
	{
		static assert(Args.length != 0);
		static if (fmt is null)
		{
			static if (Args.length > 1)
			{
				logger.log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.fatal, args);
			}
			else
			{
				logger.log!(Args[0])(LogLevel.fatal, args, line, file, funcName, prettyFuncName, moduleName);
			}
		}
		else
		{
			logger.log!string(LogLevel.fatal, format!fmt(args), line, file, funcName, prettyFuncName, moduleName);
		}
	}
	private pragma(inline) void critical(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const
	{
		static assert(Args.length != 0);
		static if (fmt is null)
		{
			static if (Args.length > 1)
			{
				logger.log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.critical, args);
			}
			else
			{
				logger.log!(Args[0])(LogLevel.critical, args, line, file, funcName, prettyFuncName, moduleName);
			}
		}
		else
		{
			logger.log!string(LogLevel.critical, format!fmt(args), line, file, funcName, prettyFuncName, moduleName);
		}
	}
}

