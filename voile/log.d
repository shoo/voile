/*******************************************************************************
 * ログ取得のためのユーティリティモジュール
 */
module voile.log;


import std.range: isInputRange, isOutputRange, isForwardRange, hasLength, hasSlicing;
import std.logger: Logger, FileLogger, MultiLogger, sharedLog, LogLevel, CreateFolder;



/*******************************************************************************
 * 
 */
struct LogData
{
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
	import std.datetime, std.concurrency, core.thread, std.logger;
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
interface LogStorageInput
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
interface LogStorageOutput
{
	import std.datetime;
	///
	void put(LogData datas);
	///
	void clear();
}
static assert(isInputRange!(LogStorageInput));
static assert(isOutputRange!(LogStorageOutput, LogData));





/*******************************************************************************
 * 
 */
class LogStorageInMemory: LogStorageInput, LogStorageOutput
{
private:
	const(LogData)[] _datas;
	size_t _idx;
public:
	///
	LogData front() @safe const @property
	{
		return _datas[_idx];
	}
	
	///
	bool empty() @safe const @property
	{
		return _idx == _datas.length;
	}
	
	///
	void popFront() @safe
	{
		_idx++;
	}
	
	///
	void put(LogData data) @safe
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
	LogStorageInMemory save() pure nothrow @safe const
	{
		auto ls = new LogStorageInMemory;
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
	LogStorageInMemory opSlice() pure nothrow @safe const
	{
		return save();
	}
	
	/// ditto
	LogStorageInMemory opSlice(size_t begin, size_t end) pure nothrow @safe const
	{
		auto ls = new LogStorageInMemory;
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

static assert(isForwardRange!LogStorageInMemory);
static assert(hasLength!LogStorageInMemory);
static assert(hasSlicing!LogStorageInMemory);
static assert(hasLength!(typeof(LogStorageInMemory.slice())));
static assert(hasSlicing!(typeof(LogStorageInMemory.slice())));
static assert(hasLength!(typeof(LogStorageInMemory.slice(0,0))));
static assert(hasSlicing!(typeof(LogStorageInMemory.slice(0,0))));


/*******************************************************************************
 * 
 */
class LogStorageLogger : Logger
{
private:
	size_t _currentId;
	LogStorageOutput _logDst;
public:
	
	///
	this(LogStorageOutput logDst, LogLevel lv = LogLevel.all) @safe
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
class InMemoryLogger: LogStorageLogger
{
private:
	LogStorageInMemory _logStorage;
	
	
public:
	
	///
	this(LogLevel lv = LogLevel.all) @safe
	{
		_logStorage = new LogStorageInMemory;
		super(_logStorage, lv);
	}
	
	///
	inout(LogStorageInMemory) logStorage() pure nothrow @safe inout @property
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

///
@system unittest
{
	auto logger = new InMemoryLogger(LogLevel.info);
	logger.trace("TRACETEST"); // ignore
	logger.info("INFOTEST");
	logger.warning("WARNINGTEST");
	logger.error("ERRORTEST");
	auto input = logger.logStorage;
	assert(!input.empty);
	assert(input.front.id == 0);
	assert(input.front.msg == "INFOTEST");
	input.popFront();
	assert(!input.empty);
	assert(input.front.id == 1);
	assert(input.front.msg == "WARNINGTEST");
	input.popFront();
	assert(!input.empty);
	assert(input.front.id == 2);
	assert(input.front.msg == "ERRORTEST");
	input.popFront();
	assert(input.empty);
}


/*******************************************************************************
 * テキストファイルのロガー
 */
class TextFileLogger: FileLogger
{
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
		import std.logger: systimeToISOString;
		import std.string : lastIndexOf;
		import std.format: formattedWrite;
		//ptrdiff_t fnIdx = file.lastIndexOf('/') + 1;
		//ptrdiff_t funIdx = funcName.lastIndexOf('.') + 1;
		auto writer = this.file.lockingTextWriter();
		writer.systimeToISOString(timestamp);
		writer.formattedWrite(" [%s] %s(%s) %s: ", logLevel, file, line, funcName);
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
	static LogStorageInput loadFromFile(string fileName)
	{
		return new class LogStorageInput
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
	auto fs = createDisposableDir("ut");
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
	input.destroy();
}

/*******************************************************************************
 * JSONファイルのロガー
 */
class JsonLineFileLogger: Logger
{
private:
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
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder) @safe
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
		_file.open(_filename, "ab");
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
		auto writer = _file.lockingTextWriter();
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
			~`}`~"\n",
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
	
	///
	static LogStorageInput loadFromFile(string fileName)
	{
		return new class LogStorageInput
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
				return line.length == 0;
			}
			///
			void popFront()
			{
				byLine.popFront();
				line = byLine.front;
				id++;
			}
			///
			void reset()
			{
				file.seek(0);
				byLine = file.byLine();
				line = byLine.front;
				id = 0;
			}
		};
	}
}

@system unittest
{
	import voile.fs;
	auto fs = createDisposableDir("ut");
	auto logger = new JsonLineFileLogger(fs.absolutePath("jsonlinelogger.jsonl"));
	logger.trace("TRACETEST");
	logger.info("INFOTEST");
	logger.warning("WARNINGTEST");
	logger.error("ERRORTEST");
	logger.destroy();
	auto input = JsonLineFileLogger.loadFromFile(fs.absolutePath("jsonlinelogger.jsonl"));
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
	input.destroy();
}

/*******************************************************************************
 * XMLファイルのロガー
 */
class XmlFileLogger: Logger
{
private:
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
		string encode(string str)
		{
			import std.string: translate;
			return str.translate([
				'&': "&amp;",
				'"': "&quot;",
				'\'': "&apos;",
				'<': "&lt;",
				'>': "&gt;"]);
		}
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
 * 
 */
abstract class RotationLogger(BaseLogger): Logger
{
protected:
	import voile.handler;
	///
	Logger logger;
	///
	string currFilePath;
	/***************************************************************************
	 * ログローテート
	 */
	void rotate(string oldFilePath, string newFilePath) @trusted
	{
		// 現在のファイルを閉じる
		destroy(logger);
		
		// 現在のファイル名をoldNameに変更する
		import std.file;
		std.file.rename(currFilePath, oldFilePath);
		
		// 新しいLoggerを開く
		logger = new BaseLogger(newFilePath, logger.logLevel);
		currFilePath = newFilePath;
		
		// ハンドラ呼び出し
		onRotated(oldFilePath, newFilePath);
	}
public:
	///
	Handler!(void delegate(string oldFilePath, string newFilePath)) onRotated;
	
	///
	this(in string fn, const LogLevel lv = LogLevel.all) @safe
	{
		this(fn, lv, CreateFolder.yes);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder) @trusted
	{
		super(lv);
		logger = new BaseLogger(fn, lv, createFileNameFolder);
		currFilePath = fn;
	}
	
	///
	abstract override void writeLogMsg(ref LogEntry payload);
}

/*******************************************************************************
 * 
 */
class SizeRotationLogger(BaseLogger): RotationLogger!BaseLogger
{
private:
	size_t _threshold;
public:
	///
	this(in string fn, const LogLevel lv = LogLevel.all, size_t threshold = 16 * 1024 * 1024) @safe
	{
		this(fn, lv, CreateFolder.yes, threshold);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder, size_t threshold = 16 * 1024 * 1024) @trusted
	{
		super(fn, lv, createFileNameFolder);
		_threshold = threshold;
	}
	
	///
	override void writeLogMsg(ref LogEntry payload) @trusted
	{
		import std.file, std.path, std.conv, std.string, std.exception, std.regex, std.format;
		if (std.file.getSize(currFilePath) >= _threshold)
		{
			auto baseLogName = currFilePath.baseName(currFilePath.extension);
			auto blobName = baseLogName ~ "-*" ~ currFilePath.extension;
			size_t latestNumber = 0;
			size_t maxSpace = 1;
			foreach (de; dirEntries(currFilePath.dirName, blobName, SpanMode.shallow))
			{
				if (!de.isFile)
					continue;
				auto scannedBaseLogName = de.name.baseName(de.name.extension);
				auto idx = scannedBaseLogName.lastIndexOf("-");
				assert(idx != -1);
				try
				{
					auto number = scannedBaseLogName[idx + 1 .. $].to!size_t();
					if (number > latestNumber)
						latestNumber = number;
				}
				catch (Exception)
					continue;
				if (scannedBaseLogName.length - idx - 1 > maxSpace)
					maxSpace = scannedBaseLogName.length - idx;
			}
			latestNumber++;
			auto oldBaseName = format("%s-%0" ~ to!string(maxSpace) ~ "d%s",
				baseLogName, latestNumber, currFilePath.extension);
			rotate(currFilePath.dirName.buildPath(oldBaseName), currFilePath);
		}
		logger.writeLogMsg(payload);
	}
}

@system unittest
{
	import std.algorithm, std.range, std.array;
	import core.thread;
	import voile.fs;
	import std.file;
	auto fs = createDisposableDir("ut");
	auto logger = new SizeRotationLogger!TextFileLogger(fs.absolutePath("test.log"), threshold: 128);
	
	logger.info("test");
	assert(fs.entries("*.log").walkLength == 1);
	assert(fs.exists("test.log"));
	assert(fs.absolutePath("test.log").getSize() < 128);
	
	logger.info("testtesttesttesttesttesttest");
	assert(fs.entries("*.log").walkLength == 1);
	assert(fs.absolutePath("test.log").getSize() > 128);
	
	Thread.sleep(1.msecs);
	logger.info("testtesttesttesttesttesttest");
	assert(fs.entries("*.log").walkLength == 2);
	assert(fs.exists("test.log"));
	assert(fs.exists("test-1.log"));
	assert(fs.getTimeStamp("test.log") > fs.getTimeStamp("test-1.log"));
	
	logger.info("testtesttesttesttesttesttest");
	logger.info("testtesttesttesttesttesttest");
	assert(fs.entries("*.log").walkLength == 3);
	assert(fs.exists("test-2.log"));
	logger.logger.destroy();
}

/*******************************************************************************
 * 
 */
class DateRotationLogger(BaseLogger): RotationLogger!BaseLogger
{
	///
	enum LogInterval
	{
		///
		hourly,
		///
		daily,
		///
		weekly,
		///
		monthly,
	}
private:
	import std.datetime;
	SysTime _nextRotateTime;
	SysTime _currRotateTime;
	LogInterval _interval;
	
	SysTime calcPrevRotateTime(SysTime tim) @safe
	{
		final switch (_interval)
		{
		case LogInterval.hourly:
			return SysTime(DateTime(tim.year, tim.month, tim.day, tim.hour, 0, 0));
		case LogInterval.daily:
			return SysTime(DateTime(tim.year, tim.month, tim.day, 0, 0, 0));
		case LogInterval.weekly:
			auto t = SysTime(DateTime(tim.year, tim.month, tim.day, 0, 0, 0));
			return t - days(cast(int)t.dayOfWeek);
		case LogInterval.monthly:
			return SysTime(DateTime(tim.year, tim.month, 1, 0, 0, 0));
		}
	}
	
	SysTime calcNextTime(SysTime tim) @safe
	{
		final switch (_interval)
		{
		case LogInterval.hourly:
			return tim + hours(1);
		case LogInterval.daily:
			return tim + days(1);
		case LogInterval.weekly:
			return tim + days(7);
		case LogInterval.monthly:
			return tim.roll!"months"(1);
		}
	}
	void rollTime() @safe
	{
		_currRotateTime = _nextRotateTime;
		_nextRotateTime = calcNextTime(calcPrevRotateTime(Clock.currTime));
	}
public:
	///
	this(in string fn, const LogLevel lv = LogLevel.all, LogInterval interval = LogInterval.daily) @safe
	{
		this(fn, lv, CreateFolder.yes, interval);
	}
	/// ditto
	this(in string fn, const LogLevel lv, CreateFolder createFileNameFolder, LogInterval interval = LogInterval.daily) @safe
	{
		super(fn, lv, createFileNameFolder);
		auto tim = Clock.currTime;
		_interval = interval;
		_currRotateTime = calcPrevRotateTime(tim);
		_nextRotateTime = calcNextTime(_currRotateTime);
	}
	
	///
	override void writeLogMsg(ref LogEntry payload) @safe
	{
		import std.file, std.path, std.format;
		if (payload.timestamp >= _nextRotateTime)
		{
			scope (exit)
				rollTime();
			auto baseLogName = currFilePath.baseName(currFilePath.extension);
			auto ot = _currRotateTime;
			string oldBaseName;
			final switch (_interval)
			{
			case LogInterval.hourly:
				oldBaseName = format("%s-%04d%02d%02d%02d", baseLogName, ot.year, ot.month, ot.day, ot.hour);
				break;
			case LogInterval.daily:
				oldBaseName = format("%s-%04d%02d%02d", baseLogName, ot.year, ot.month, ot.day);
				break;
			case LogInterval.weekly:
				oldBaseName = format("%s-%04d%02d%02d", baseLogName, ot.year, ot.month, ot.day);
				break;
			case LogInterval.monthly:
				oldBaseName = format("%s-%04d%02d", baseLogName, ot.year, ot.month);
				break;
			}
			auto oldFilePath = currFilePath.dirName.buildPath(format("%s%s", oldBaseName, currFilePath.extension));
			size_t dupIndex = 1;
			while (oldFilePath.exists)
			{
				oldFilePath = currFilePath.dirName.buildPath(
					format("%s-%d%s", baseLogName, oldBaseName, dupIndex, currFilePath.extension));
				dupIndex++;
			}
			rotate(oldFilePath, currFilePath);
		}
		logger.writeLogMsg(payload);
	}
}

@system unittest
{
	import std.algorithm, std.range, std.array;
	import core.thread;
	import voile.fs;
	import std.datetime;
	import std.file;
	auto fs = createDisposableDir("ut");
	alias LI = DateRotationLogger!TextFileLogger.LogInterval;
	auto logger = new DateRotationLogger!TextFileLogger(fs.absolutePath("test.log"), interval: LI.daily);
	auto prev = SysTime(DateTime(2022, 11, 6, 17, 0, 0));
	auto never = SysTime(DateTime(9999, 12, 31, 23, 59, 59));
	auto next = SysTime(DateTime(2024, 11, 7, 15, 0, 0));
	auto currTime = Clock.currTime;
	
	logger._currRotateTime = prev;
	logger._nextRotateTime = never;
	logger.info("test");
	assert(fs.entries("*.log").walkLength == 1);
	assert(fs.exists("test.log"));
	assert(logger._currRotateTime is prev);
	assert(logger._nextRotateTime is never);
	
	logger._nextRotateTime = next;
	logger.info("test");
	assert(fs.entries("*.log").walkLength == 2);
	assert(fs.exists("test.log"));
	assert(fs.exists("test-20221106.log"));
	assert(logger._currRotateTime is next);
	assert(logger._nextRotateTime > currTime);
	
	logger.logger.destroy();
}


/*******************************************************************************
 * 
 */
class NamedLogger: MultiLogger
{
	
	/***************************************************************************
	 * ロガーを取得する
	 */
	Logger getLogger(string name) @safe
	{
		import std.algorithm, std.range;
		auto found = logger.find!(l => l.name == name)();
		return found.empty ? null : found.front.logger;
	}
	
	/***************************************************************************
	 * ロガーを追加する
	 * 
	 * 重複チェックをする
	 */
	override void insertLogger(string name, Logger l) @safe
	{
		import std.exception;
		enforce(!getLogger(name));
		super.insertLogger(name, l);
	}
}


/*******************************************************************************
 * 
 */
class DispatchLogger: NamedLogger
{
	import std.regex;
	/***************************************************************************
	 * 
	 */
	struct Filter
	{
	private:
		///
		Regex!char _file;
		///
		Regex!char _moduleName;
		///
		Regex!char _funcName;
		///
		Regex!char _prettyFuncName;
		///
		Regex!char _msg;
		///
		string     _targetName;
		///
		size_t     _lineMax = size_t.max;
		///
		size_t     _lineMin = size_t.min;
		///
		LogLevel   _logLevel = LogLevel.all;
	public:
		///
		inout(Regex!char) file() @safe inout @property
		{
			return _file;
		}
		/// ditto
		void file(string pattern) @safe @property
		{
			_file = regex(pattern);
		}
		/// ditto
		void file(Regex!char r) @safe @property
		{
			_file = r;
		}
		///
		inout(Regex!char) moduleName() @safe inout @property
		{
			return _moduleName;
		}
		/// ditto
		void moduleName(string pattern) @safe @property
		{
			_moduleName = regex(pattern);
		}
		/// ditto
		void moduleName(Regex!char r) @safe @property
		{
			_moduleName = r;
		}
		///
		inout(Regex!char) funcName() @safe inout @property
		{
			return _funcName;
		}
		/// ditto
		void funcName(string pattern) @safe @property
		{
			_funcName = regex(pattern);
		}
		/// ditto
		void funcName(Regex!char r) @safe @property
		{
			_funcName = r;
		}
		///
		inout(Regex!char) prettyFuncName() @safe inout @property
		{
			return _prettyFuncName;
		}
		/// ditto
		void prettyFuncName(string pattern) @safe @property
		{
			_prettyFuncName = regex(pattern);
		}
		/// ditto
		void prettyFuncName(Regex!char r) @safe @property
		{
			_prettyFuncName = r;
		}
		///
		inout(Regex!char) msg() @safe inout @property
		{
			return _msg;
		}
		/// ditto
		void msg(string pattern) @safe @property
		{
			_msg = regex(pattern);
		}
		/// ditto
		void msg(Regex!char r) @safe @property
		{
			_msg = r;
		}
		///
		string targetName() @safe inout @property
		{
			return _targetName;
		}
		/// ditto
		void targetName(string name) @safe @property
		{
			_targetName = name;
		}
		///
		size_t lineMax() @safe const @property
		{
			return _lineMax;
		}
		/// ditto
		void lineMax(size_t num) @safe @property
		{
			_lineMax = num;
		}
		///
		size_t lineMin() @safe const @property
		{
			return _lineMin;
		}
		/// ditto
		void lineMin(size_t num) @safe @property
		{
			_lineMin = num;
		}
		/// ditto
		void setLineSpan(size_t min, size_t max) @safe
		{
			_lineMin = min;
			_lineMax = max;
		}
		///
		LogLevel logLevel() @safe const @property
		{
			return _logLevel;
		}
		/// ditto
		void logLevel(LogLevel lv) @safe @property
		{
			_logLevel = lv;
		}
		
		/***********************************************************************
		 * Constructor
		 */
		this(string targetName,
			string file = null, string moduleName = null,
			string funcName = null, string prettyFuncName = null,
			string msg = null,
			size_t lineMax = size_t.max, size_t lineMin = size_t.min, LogLevel logLevel = LogLevel.all) @safe
		{
			_targetName = targetName;
			if (file)
				_file = regex(file);
			if (moduleName)
				_moduleName = regex(moduleName);
			if (funcName)
				_funcName = regex(funcName);
			if (prettyFuncName)
				_prettyFuncName = regex(prettyFuncName);
			if (msg)
				_msg = regex(msg);
			_lineMax = lineMax;
			_lineMin = lineMin;
			_logLevel = logLevel;
		}
	}
	
private:
	Filter[] _filters;
public:
	/***************************************************************************
	 * 
	 */
	void addFilter(Filter filter) @safe
	{
		_filters ~= filter;
	}
	/***************************************************************************
	 * 
	 */
	override void writeLogMsg(ref LogEntry payload) @safe
	{
		import std.exception;
		foreach (f; _filters)
		{
			bool filtered = true;
			filtered &= (f._file           is Regex!char.init || payload.file.matchFirst(f._file));
			filtered &= (f._moduleName     is Regex!char.init || payload.moduleName.matchFirst(f._moduleName));
			filtered &= (f._funcName       is Regex!char.init || payload.funcName.matchFirst(f._funcName));
			filtered &= (f._prettyFuncName is Regex!char.init || payload.prettyFuncName.matchFirst(f._prettyFuncName));
			filtered &= (f._msg            is Regex!char.init || payload.msg.matchFirst(f._msg));
			filtered &= (f._logLevel <= payload.logLevel);
			filtered &= ((f._lineMax >= payload.line) && (f._lineMin <= payload.line));
			// フィルタにかからない場合は次
			if (!filtered)
				continue;
			if (auto logger = getLogger(f._targetName))
			{
				// 宛先がある場合は、宛先にのみ分配
				logger.writeLogMsg(payload);
				return;
			}
			else
			{
				// 宛先がない場合は全てに分配
				super.writeLogMsg(payload);
				return;
			}
		}
		// 全てのフィルタに引っかからなかった場合は破棄
		return;
	}
}

///
@safe unittest
{
	auto logger = new DispatchLogger;
	with (logger)
	{
		insertLogger("test1", new InMemoryLogger);
		insertLogger("test2", new InMemoryLogger);
		addFilter(Filter("test1", msg: r"test\d{3}"));
		addFilter(Filter("test2", logLevel: LogLevel.warning));
	}
	logger.info("test001");    // -> test1
	logger.trace("aaa");       // -> drop
	logger.warning("xxx");     // -> test2
	logger.warning("test002"); // -> test1
	import std.algorithm: equal, map;
	assert((cast(InMemoryLogger)logger.getLogger("test1")).logStorage.map!"a.msg".equal(["test001", "test002"]));
	assert((cast(InMemoryLogger)logger.getLogger("test2")).logStorage.map!"a.msg".equal(["xxx"]));
}

/*******************************************************************************
 * マルチスレッド同期機構を備えたLogger
 */
class SynchronizedLogger: Logger
{
private:
	Logger _logger;
public:
	///
	this(Logger logger, LogLevel lv = LogLevel.all)
	{
		_logger = logger;
		super(lv);
	}
	/// ditto
	this(shared Logger logger, LogLevel lv = LogLevel.all)
	{
		_logger = cast()logger;
		super(lv);
	}
	/// ditto
	this(Logger logger, LogLevel lv = LogLevel.all) shared
	{
		_logger = cast(shared)logger;
		super(lv);
	}
	/// ditto
	this(shared Logger logger, LogLevel lv = LogLevel.all) shared
	{
		_logger = logger;
		super(lv);
	}
	
	///
	override void writeLogMsg(ref LogEntry payload) @trusted
	{
		synchronized (_logger)
			_logger.writeLogMsg(payload);
	}
}


/*******************************************************************************
 * クラス内で使用するロガーを切り替えるためのミックスインテンプレート
 */
mixin template Logging(loggerAlias...)
{
	private import std.string: format;
	private import std.logger: Logger;
	static if (loggerAlias.length == 1 && is(typeof(loggerAlias[0]): Logger))
	{
		private pragma(inline) typeof(loggerAlias[0]) logger() @trusted const
		{
			return cast()loggerAlias[0];
		}
	}
	else
	{
		private Logger _logger;
		private pragma(inline) Logger logger() @trusted const
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
		string moduleName = __MODULE__, Args...)(Args args) const nothrow
	{
		static assert(Args.length != 0);
		try
		{
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
		catch (Exception)
		{
			// なにもしない
		}
	}
	private pragma(inline) void error(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const nothrow
	{
		static assert(Args.length != 0);
		try
		{
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
		catch (Exception)
		{
			// なにもしない
		}
	}
	private pragma(inline) void fatal(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const nothrow
	{
		static assert(Args.length != 0);
		try
		{
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
		catch (Exception)
		{
			// なにもしない
		}
	}
	private pragma(inline) void critical(string fmt = null, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, Args...)(Args args) const nothrow
	{
		static assert(Args.length != 0);
		try
		{
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
		catch (Exception)
		{
			// なにもしない
		}
	}
}


/*******************************************************************************
 * 名前からロガーを取得する
 */
Logger getLogger(string name, Logger defaultLogger = cast()sharedLog) @trusted
{
	auto logger = cast(NamedLogger)cast()sharedLog;
	if (!logger)
		return defaultLogger;
	auto named = logger.getLogger(name);
	if (!named)
		return defaultLogger;
	return named;
}
