/*******************************************************************************
 * ログ取得のためのユーティリティモジュール
 */
module voile.log;


import std.range: isInputRange, isOutputRange, isForwardRange, hasLength, hasSlicing;
import std.experimental.logger: Logger, FileLogger;



/*******************************************************************************
 * 
 */
struct LogData
{
	import std.experimental.logger;
	import std.datetime, std.json;
	import voile.json;
	///
	ulong    id;
	///
	LogLevel level;
	///
	SysTime  time;
	///
	string   file;
	///
	uint     line;
	///
	string   msg;
	///
	string   moduleName;
	///
	string   funcName;
	///
	string   prettyFuncName;
	///
	string   threadId;
	
	///
	JSONValue json() @safe nothrow const @property
	{
		JSONValue ret;
		ret.setValue("id", id);
		ret.setValue("level", level);
		ret.setValue("time", time.toISOExtString);
		ret.setValue("file", file);
		ret.setValue("line", line);
		ret.setValue("msg", msg);
		ret.setValue("moduleName", moduleName);
		ret.setValue("funcName", funcName);
		ret.setValue("prettyFuncName", prettyFuncName);
		ret.setValue("threadId", threadId);
		return ret;
	}
	///
	void json(JSONValue v) @safe nothrow @property
	{
		try
		{
			id             = v.getValue("id", id.init);
			level          = v.getValue("level", level.init);
			time           = SysTime.fromISOExtString(v.getValue("time", string.init));
			file           = v.getValue("file", file.init);
			line           = v.getValue("line", line.init);
			msg            = v.getValue("msg", msg.init);
			moduleName     = v.getValue("moduleName", moduleName.init);
			funcName       = v.getValue("funcName", funcName.init);
			prettyFuncName = v.getValue("prettyFuncName", prettyFuncName.init);
			threadId       = v.getValue("threadId", threadId.init);
		}
		catch (Exception e)
		{
			/* DO NOTHING */
		}
	}
	
	///
	string toString() const
	{
		return json.toString();
	}
}

@safe unittest
{
	import std.datetime, std.concurrency, core.thread, std.experimental.logger;
	LogData logData1;
	with (logData1)
	{
		id         = 0;
		level      = LogLevel.warning;
		time       = Clock.currTime();
		file       = __FILE__;
		line       = __LINE__;
		moduleName = __MODULE__;
		funcName   = __FUNCTION__;
		threadId   = "Thread";
		msg        = "message";
	}
	LogData logData2;
	logData2.json = logData1.json;
	
	assert(logData2.id == logData1.id);
	assert(logData2.level == logData1.level);
	assert(logData2.time == logData1.time);
	assert(logData2.file == logData1.file);
	assert(logData2.line == logData1.line);
	assert(logData2.moduleName == logData1.moduleName);
	assert(logData2.funcName == logData1.funcName);
	assert(logData2.threadId == logData1.threadId);
	assert(logData2.msg == logData1.msg);
}


/*******************************************************************************
 * 
 */
interface LogStrageInput
{
	///
	LogData front() const @property;
	///
	bool empty() const @property;
	///
	void popFront();
	///
	void reset();
}

/*******************************************************************************
 * 
 */
interface LogStrageOutput
{
	import std.datetime;
	///
	void put(LogData datas);
	///
	void clear();
}
static assert(isInputRange!(LogStrageInput));
static assert(isOutputRange!(LogStrageOutput, LogData));





/*******************************************************************************
 * 
 */
class LogStrageInMemory: LogStrageInput, LogStrageOutput
{
private:
	const(LogData)[] _datas;
	size_t _idx;
public:
	///
	LogData front() const @property
	{
		return _datas[_idx];
	}
	
	///
	bool empty() const @property
	{
		return _idx == _datas.length;
	}
	
	///
	void popFront()
	{
		_idx++;
	}
	
	///
	void put(LogData data)
	{
		_datas ~= data;
	}
	
	///
	void reset() pure nothrow @safe @nogc
	{
		_idx = 0;
	}
	///
	void clear() pure nothrow @safe @nogc
	{
		_idx = 0;
		_datas = null;
	}
	
	///
	LogStrageInMemory save() pure nothrow @safe const
	{
		auto ls = new LogStrageInMemory;
		ls._idx   = _idx;
		ls._datas = _datas;
		return ls;
	}
	
	///
	size_t currentIndex() pure nothrow @nogc @safe const @property
	{
		return _idx;
	}
	
	///
	size_t length() pure nothrow @nogc @safe const @property
	{
		return _datas.length;
	}
	
	/// 
	LogStrageInMemory opSlice() pure nothrow @safe const
	{
		return save();
	}
	
	/// ditto
	LogStrageInMemory opSlice(size_t begin, size_t end) pure nothrow @safe const
	{
		auto ls = new LogStrageInMemory;
		ls._idx   = 0;
		ls._datas = _datas[begin..end];
		return ls;
	}
	
	/// 
	auto slice() pure nothrow @safe const
	{
		return _datas[];
	}
	
	/// ditto
	auto slice(size_t begin, size_t end) pure nothrow @safe const
	{
		return _datas[begin..end];
	}
	
	///
	alias opDoller = length;
}

static assert(isForwardRange!LogStrageInMemory);
static assert(hasLength!LogStrageInMemory);
static assert(hasSlicing!LogStrageInMemory);
static assert(hasLength!(typeof(LogStrageInMemory.slice())));
static assert(hasSlicing!(typeof(LogStrageInMemory.slice())));
static assert(hasLength!(typeof(LogStrageInMemory.slice(0,0))));
static assert(hasSlicing!(typeof(LogStrageInMemory.slice(0,0))));


/*******************************************************************************
 * 
 */
class LogStrageLogger : Logger
{
private:
	import std.experimental.logger: LogLevel;
	size_t _currentId;
	LogStrageOutput _logDst;
public:
	///
	this(LogStrageOutput logDst, LogLevel lv = LogLevel.all)
	{
		_logDst = logDst;
		_currentId = 0;
		super(lv);
	}
	
	///
	override void writeLogMsg(ref LogEntry payload) @trusted
	{
		import std.conv, core.thread, std.range;
		LogData log;
		log.id         = _currentId++;
		log.level      = payload.logLevel;
		log.time       = payload.timestamp;
		log.msg        = payload.msg;
		log.file       = payload.file;
		log.line       = payload.line;
		log.moduleName = payload.moduleName;
		log.funcName   = payload.funcName;	
		log.threadId   = text(payload.threadId);
		put(_logDst, log);
	}
}


/*******************************************************************************
 * メモリ内のロガー
 */
class InMemoryLogger: LogStrageLogger
{
private:
	import std.experimental.logger: LogLevel;
	LogStrageInMemory _logStorage;
	
	
public:
	
	///
	this(LogLevel lv = LogLevel.all)
	{
		super(_logStorage, lv);
	}
	
	///
	inout(LogStrageInMemory) logStorage() pure nothrow @safe inout
	{
		return _logStorage;
	}
	
	/// 
	auto slice() pure nothrow @safe const
	{
		return _logStorage.slice;
	}
	
	/// ditto
	auto slice(size_t begin, size_t end) pure nothrow @safe const
	{
		return _logStorage.slice(begin, end);
	}
	
}

/*******************************************************************************
 * テキストファイルのロガー
 */
class TextFileLogger: FileLogger
{
	import std.experimental.logger: LogLevel, CreateFolder;
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
	import std.experimental.logger: LogLevel, CreateFolder;
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
			~`"time":"%s",`
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
	
	///
	static LogStrageInput loadFromFile(string fileName)
	{
		return new class LogStrageInput
		{
			import std.stdio;
			File file;
			typeof(file.byLine()) byLine;
			const(char)[] line;
			ulong id;
			
			this()
			{
				file.open(fileName, "r");
				reset();
			}
			///
			LogData front() const @property
			{
				import voile.json;
				LogData ret;
				ret.deserializeFromJsonString(cast(string)line);
				ret.id = id;
				return ret;
			}
			///
			bool empty() const @property
			{
				return line == "]";
			}
			///
			void popFront()
			{
				import std.string;
				byLine.popFront();
				line = byLine.front.chomp(",");
				id++;
			}
			///
			void reset()
			{
				file.seek(0);
				byLine = file.byLine();
				popFront();
				id = 0;
			}
		};
	}
}

@system unittest
{
	import voile.fs;
	auto fs = FileSystem("ut");
	scope (exit)
		fs.removeFiles("ut");
	auto logger = new JsonFileLogger(fs.absolutePath("jsonlogger.json"));
	logger.trace("TRACETEST");
	logger.info("INFOTEST");
	logger.warning("WARNINGTEST");
	logger.error("ERRORTEST");
	logger.destroy();
	auto input = JsonFileLogger.loadFromFile(fs.absolutePath("jsonlogger.json"));
	assert(!input.empty);
	assert(input.front.id == 0);
	assert(input.front.msg == "TRACETEST");
	input.popFront();
	assert(!input.empty);
	assert(input.front.id == 1);
	assert(input.front.msg == "INFOTEST");
	input.popFront();
	assert(!input.empty);
	assert(input.front.id == 2);
	assert(input.front.msg == "WARNINGTEST");
	input.popFront();
	assert(!input.empty);
	assert(input.front.id == 3);
	assert(input.front.msg == "ERRORTEST");
	input.popFront();
	assert(input.empty);
}


/*******************************************************************************
 * XMLファイルのロガー
 */
class XmlFileLogger: Logger
{
private:
	import std.experimental.logger: LogLevel, CreateFolder;
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
			~` time="%s"`
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
	import std.experimental.logger: LogLevel, CreateFolder;
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
	import std.experimental.logger: LogLevel, CreateFolder;
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

