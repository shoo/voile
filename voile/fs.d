/*******************************************************************************
 * ファイルシステムヘルパー
 */
module voile.fs;

import std.file, std.path, std.exception, std.stdio, std.datetime, std.regex, std.json, std.traits;
import std.process;
import voile.handler;



/*******************************************************************************
 * パスを分解してパンくずリストにする
 * 
 * Params:
 *     path  = 変換したい絶対/相対パス
 */
static string[] splitPath(string path) @safe pure
{
	import std.array: split;
	import std.algorithm: remove;
	if (path.length == 0)
		return null;
	return path[0] == '/'
		? ["/"] ~ path[1..$].split!(a => a == '\\' || a == '/').remove!(a=>a.length == 0)
		: path.split!(a => a == '\\' || a == '/').remove!(a=>a.length == 0);
}



/*******************************************************************************
 * パンくずリストをPosixパスに再構築する
 * 
 * Params:
 *     path      = 変換したい絶対/相対パス
 *     delimiter = パスの区切り文字を指定する
 */
static string joinPath(string[] path, string delimiter = dirSeparator) @safe pure
{
	import std.array: join;
	return path.join(delimiter);
}

/*******************************************************************************
 * パンくずリストをWindowsパスに再構築する
 * 
 * Params:
 *     path  = 変換したい絶対/相対パス
 */
static string joinWindowsPath(string[] path) @safe pure
{
	return path.joinPath("\\");
}

/*******************************************************************************
 * パンくずリストをPosixパスに再構築する
 * 
 * Params:
 *     path  = 変換したい絶対/相対パス
 */
static string joinPosixPath(string[] path) @safe pure
{
	if (path.length == 0)
		return null;
	if (path[0] == "/")
		return path.joinPath("/")[1..$];
	return path.joinPath("/");
}


/*******************************************************************************
 * パンをPosixパスに変換する(/を使うように変換)
 * 
 * Params:
 *     path  = 変換したい絶対/相対パス
 */
string posixPath(string path)
{
	return path.splitPath.joinPosixPath();
}

/*******************************************************************************
 * パンをWindowsパスに変換する(\を使うように変換)
 * 
 * Params:
 *     path  = 変換したい絶対/相対パス
 */
string windowsPath(string path)
{
	return path.splitPath.joinWindowsPath();
}


version (Windows)
{
	private File nullFile(string attr)
	{
		return File.init;
	}
}
else
{
	private File nullFile(string attr)
	{
		return File("/dev/null", attr);
	}
}

version (Windows)
{
	/// In Windows
	alias joinNativePath = joinWindowsPath;
	/// ditto
	alias nativePath = windowsPath;
}
else
{
	/// In Posix
	alias joinNativePath = joinPosixPath;
	/// ditto
	alias nativePath = posixPath;
}


version (Windows)
{
	enum SYMBOLIC_LINK_FLAG_DIRECTORY = 0x00000001;
	enum SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x00000002;
	extern (Windows) imported!"core.sys.windows.windows".BOOL CreateSymbolicLinkW(
		imported!"core.sys.windows.windows".LPCWSTR,
		imported!"core.sys.windows.windows".LPCWSTR,
		imported!"core.sys.windows.windows".DWORD);
}

/*******************************************************************************
 * ファイルシステムの操作に関するヘルパ
 */
struct FileSystem
{
	///
	string workDir;
	
	/// 作成前に呼ばれる。作成しない場合は例外を投げる
	Handler!(void delegate(string target, uint retrycnt))           onCreating;
	/// 作成後に呼ばれる。
	Handler!(void delegate(string target))                          onCreated;
	/// 作成に失敗したら呼ばれる。処理を継続を継続するならtrueを返す。
	Handler!(bool delegate(string target, Exception e))             onCreateFailed;
	/// コピー前に呼ばれる。コピーしない場合は例外を投げる。
	Handler!(void delegate(string target, uint retrycnt))           onCopying;
	/// コピー後に呼ばれる。
	Handler!(void delegate(string src, string target))              onCopied;
	/// コピー失敗したら呼ばれる。処理を継続を継続するならtrueを返す。
	Handler!(bool delegate(string src, string target, Exception e)) onCopyFailed;
	/// 削除前に呼ばれる。削除しない場合は例外を投げる。
	Handler!(void delegate(string target, uint retrycnt))           onRemoving;
	/// 削除後に呼ばれる。
	Handler!(void delegate(string target))                          onRemoved;
	/// 削除に失敗したら呼ばれる。処理を継続を継続するならtrueを返す。
	Handler!(bool delegate(string target, Exception e))             onRemoveFailed;
	/// インスタンスが破棄される際に呼ばれる
	Handler!(void delegate(string target))                          onDestroyed;
	
	/***************************************************************************
	 * ムーブの後に呼ばれる
	 */
	void onPostMove()
	{
		workDir = null;
	}
	
	/***************************************************************************
	 * 破棄する際に workDir に値がある場合に呼ばれる
	 */
	~this() @trusted
	{
		if (workDir)
			onDestroyed(workDir);
	}
	
	/***************************************************************************
	 * 絶対パスに変換する
	 * 
	 * Params:
	 *     target     = 変換したい相対パス(何も指定しないとworkDirの絶対パスが返る)
	 *     targetPath = 変換したい相対パスのパンくずリスト
	 *     base       = 基準となるパス(このパスの基準はworkDir)
	 */
	string absolutePath() const @safe
	{
		if (workDir.length == 0)
			return null;
		version (Windows) if (workDir[0] == '/')
			return workDir.buildNormalizedPath();
		if (workDir.isAbsolute)
			return workDir.buildNormalizedPath();
		return .absolutePath(workDir).buildNormalizedPath();
	}
	/// ditto
	string absolutePath(string target) const @safe
	{
		if (target.length == 0)
			return null;
		version (Windows) if (target[0] == '/')
			return target.buildNormalizedPath();
		if (target.isAbsolute)
			return target.buildNormalizedPath();
		return .absolutePath(target, absolutePath()).buildNormalizedPath();
	}
	/// ditto
	string absolutePath(string[] targetPath) const @safe
	{
		return this.absolutePath(.buildPath(targetPath));
	}
	/// ditto
	string absolutePath(string target, string base) const @safe
	{
		if (target.length == 0)
			return null;
		version (Windows) if (target[0] == '/')
			return target.buildNormalizedPath();
		if (target.isAbsolute)
			return target.buildNormalizedPath();
		return .absolutePath(target, this.absolutePath(base)).buildNormalizedPath();
	}
	/// ditto
	string absolutePath(string[] targetPath, string base) const @safe
	{
		return this.absolutePath(.buildPath(targetPath), base);
	}
	
	@safe unittest
	{
		auto fs = FileSystem("ut");
		assert(fs.absolutePath(".") == .absolutePath("ut").buildNormalizedPath());
	}
	
	/*******************************************************************************
	 * 実際のパス名に修正する
	 */
	string actualPath(string path = ".") const @safe
	{
		version (Windows)
		{
			import core.sys.windows.shellapi;
			import core.stdc.wchar_: wcslen;
			import std.utf: toUTF16z, toUTF8;
			SHFILEINFOW info;
			info.szDisplayName[0] = 0;
			auto paths = absolutePath(path).pathSplitter();
			string result;
			import std.uni: toUpper;
			result = paths.front.toUpper();
			paths.popFront();
			foreach (p; paths)
			{
				() @trusted { SHGetFileInfoW(result.buildPath(p).toUTF16z(), 0, &info, info.sizeof, SHGFI_DISPLAYNAME); }();
				() @trusted { result = result.buildPath(toUTF8(info.szDisplayName.ptr[0..wcslen(info.szDisplayName.ptr)])); }();
			}
			return result;
		}
		else
		{
			return absolutePath(path);
		}
	}
	@system unittest
	{
		version (Windows)
		{
			auto fs = FileSystem("C:/");
			assert(fs.actualPath(r"wInDoWs") == r"C:\Windows");
		}
		else
		{
			// テストなし
		}
	}
	
	
	/***************************************************************************
	 * 相対パスに変換する
	 * 
	 * Params:
	 *     target     = 変換したい絶対/相対パス
	 *     targetPath = 変換したい相対パスのパンくずリスト
	 *     base       = 基準となるパス(このパスの基準はworkDir)
	 */
	string relativePath(string target) const @safe
	{
		return .relativePath(this.absolutePath(target), this.absolutePath());
	}
	/// ditto
	string relativePath(string[] targetPath) const @safe
	{
		return .relativePath(this.absolutePath(targetPath), this.absolutePath());
	}
	/// ditto
	string relativePath(string target, string base) const @safe
	{
		return .relativePath(this.absolutePath(target), this.absolutePath(base));
	}
	/// ditto
	string relativePath(string[] targetPath, string base) const @safe
	{
		return .relativePath(this.absolutePath(targetPath), this.absolutePath(base));
	}
	
	@safe unittest
	{
		version (Windows)
		{
			auto fs = FileSystem("C:/work");
			assert(fs.relativePath(r"C:/Windows") == r"..\Windows");
			assert(fs.relativePath(r"C:/Program Files", "../Windows") == r"..\Program Files");
		}
		else
		{
			auto fs = FileSystem("/usr/local");
			assert(fs.relativePath(r"/usr/bin") == r"../bin");
			assert(fs.relativePath(r"/usr/bin", "../lib") == r"../bin");
		}
	}
	
	
	/***************************************************************************
	 * パスをパンくず表現に変換
	 * 
	 * Params:
	 *     path  = 変換したい絶対/相対パス
	 *     paths = 変換したい相対パスのパンくずリスト
	 */
	string[] buildSplittedPath(string path) const @safe
	{
		if (path.isAbsolute())
			return splitPath(path);
		version (Windows)
		{
			if (path.length == 0)
				return null;
			if (path[0] == '/')
				return splitPath(path);
		}
		return splitPath(workDir) ~ splitPath(path);
	}
	
	/// ditto
	string[] buildSplittedPath(string[] paths) const @safe
	{
		return buildSplittedPath(paths.buildPath());
	}
	
	/// ditto
	string[] buildSplittedPath() const @safe
	{
		return splitPath(workDir);
	}
	
	@safe unittest
	{
		auto fs = FileSystem("ut/path");
		auto pathsplitted = fs.buildSplittedPath();
		assert(pathsplitted.length == 2);
		assert(pathsplitted[0] == "ut");
		assert(pathsplitted[1] == "path");
		pathsplitted = fs.buildSplittedPath("../path\\aaa/bbb");
		assert(pathsplitted.length == 6);
		assert(pathsplitted[0] == "ut");
		assert(pathsplitted[1] == "path");
		assert(pathsplitted[2] == "..");
		assert(pathsplitted[3] == "path");
		assert(pathsplitted[4] == "aaa");
		assert(pathsplitted[5] == "bbb");
		pathsplitted = fs.buildSplittedPath("/path\\aaa/bbb");
		assert(pathsplitted[0] == "/");
		assert(pathsplitted[1] == "path");
		assert(pathsplitted[2] == "aaa");
		assert(pathsplitted[3] == "bbb");
	}
	
	
	/***************************************************************************
	 * パスをPosix表現に変換
	 * 
	 * Params:
	 *     path  = 変換したい絶対/相対パス
	 *     paths = 変換したい相対パスのパンくずリスト
	 */
	string buildPosixPath(string path) const @safe
	{
		return buildSplittedPath(path).joinPosixPath();
	}
	
	/// ditto
	string buildPosixPath(string[] paths) const @safe
	{
		return buildSplittedPath(paths).joinPosixPath();
	}
	
	/// ditto
	string buildPosixPath() const @safe
	{
		return buildSplittedPath().joinPosixPath();
	}
	
	/// ditto
	@safe unittest
	{
		auto fs = FileSystem("ut\\test");
		assert(fs.buildPosixPath() == "ut/test");
		auto posixPath = fs.buildPosixPath("path\\to/file");
		assert(posixPath == "ut/test/path/to/file");
		
		auto absPosixPath = fs.buildPosixPath("/path\\to/file");
		assert(absPosixPath == "/path/to/file");
		
	}
	
	/***************************************************************************
	 * パスをWindows表現に変換
	 * 
	 * Params:
	 *     path  = 変換したい絶対/相対パス
	 *     paths = 変換したい相対パスのパンくずリスト
	 */
	string buildWindowsPath(string path) const @safe
	{
		return buildSplittedPath(path).joinWindowsPath();
	}
	
	/// ditto
	string buildWindowsPath(string[] paths) const @safe
	{
		return buildSplittedPath(paths).joinWindowsPath();
	}
	
	/// ditto
	string buildWindowsPath() const @safe
	{
		return buildSplittedPath().joinWindowsPath();
	}
	
	/// ditto
	@safe unittest
	{
		auto fs = FileSystem("ut/test");
		assert(fs.buildWindowsPath() == "ut\\test");
		auto posixPath = fs.buildWindowsPath("path\\to/file");
		assert(posixPath == "ut\\test\\path\\to\\file");
	}
	
	
	
	/***************************************************************************
	 * パスを正規化して分解してパンくずリストにする
	 * 
	 * Params:
	 *     path  = 変換したい絶対/相対パス
	 *     paths = 変換したい相対パスのパンくずリスト
	 */
	string[] buildNormalizedSplittedPath(string path) const @safe
	{
		import std.array;
		auto splitted = buildSplittedPath(path).buildNormalizedPath().split!(a => a == '\\' || a == '/');
		if (splitted.length == 0 || splitted[0] != "")
			return splitted;
		splitted[0] = "/";
		return splitted;
	}
	
	/// ditto
	string[] buildNormalizedSplittedPath(string[] paths) const @safe
	{
		import std.array;
		auto splitted = buildSplittedPath(paths).buildNormalizedPath().split!(a => a == '\\' || a == '/');
		if (splitted.length == 0 || splitted[0] != "")
			return splitted;
		splitted[0] = "/";
		return splitted;
	}
	
	/// ditto
	string[] buildNormalizedSplittedPath() const @safe
	{
		import std.array;
		auto splitted = buildSplittedPath().buildNormalizedPath().split!(a => a == '\\' || a == '/');
		if (splitted.length == 0 || splitted[0] != "")
			return splitted;
		splitted[0] = "/";
		return splitted;
	}
	
	@safe unittest
	{
		auto fs = FileSystem("ut/path/");
		auto pathsplitted = fs.buildNormalizedSplittedPath();
		assert(pathsplitted.length == 2);
		assert(pathsplitted[0] == "ut");
		assert(pathsplitted[1] == "path");
		pathsplitted = fs.buildNormalizedSplittedPath("../path/./\\aaa/bbb");
		assert(pathsplitted.length == 4);
		assert(pathsplitted[0] == "ut");
		assert(pathsplitted[1] == "path");
		assert(pathsplitted[2] == "aaa");
		assert(pathsplitted[3] == "bbb");
		auto abspathsplitted = fs.buildNormalizedSplittedPath("/test");
		assert(abspathsplitted.length == 2);
		assert(abspathsplitted[0] == "/");
		assert(abspathsplitted[1] == "test");
	}
	
	/***************************************************************************
	 * パスを正規化してPosix表現に変換
	 * 
	 * Params:
	 *     path  = 変換したい絶対/相対パス
	 *     paths = 変換したい相対パスのパンくずリスト
	 */
	string buildNormalizedPosixPath(string path)
	{
		import std.array;
		auto splitted = buildNormalizedSplittedPath(path);
		if (splitted.length == 0)
			return null;
		return splitted.join('/')[(splitted[0] == "/" ? 1 : 0) .. $];
	}
	
	/// ditto
	string buildNormalizedPosixPath(string[] paths)
	{
		import std.array;
		auto splitted = buildNormalizedSplittedPath(paths);
		if (splitted.length == 0)
			return null;
		return splitted.join('/')[(splitted[0] == "/" ? 1 : 0) .. $];
	}
	
	/// ditto
	string buildNormalizedPosixPath()
	{
		import std.array;
		auto splitted = buildNormalizedSplittedPath();
		if (splitted.length == 0)
			return null;
		return splitted.join('/')[(splitted[0] == "/" ? 1 : 0) .. $];
	}
	
	/// ditto
	@system unittest
	{
		auto fs = FileSystem("ut\\test");
		assert(fs.buildNormalizedPosixPath() == "ut/test");
		auto posixPath = fs.buildNormalizedPosixPath("../path\\to/file");
		assert(posixPath == "ut/path/to/file");
	}
	
	@system unittest
	{
		auto fs = FileSystem("ut\\test\\");
		assert(fs.buildNormalizedPosixPath() == "ut/test");
		auto posixPath = fs.buildNormalizedPosixPath("../path\\to/file");
		assert(posixPath == "ut/path/to/file");
	}
	
	/***************************************************************************
	 * パスを正規化してWindows表現に変換
	 * 
	 * Params:
	 *     path  = 変換したい絶対/相対パス
	 *     paths = 変換したい相対パスのパンくずリスト
	 */
	string buildNormalizedWindowsPath(string path)
	{
		import std.array;
		return buildNormalizedSplittedPath(path).join('\\');
	}
	
	/// ditto
	string buildNormalizedWindowsPath(string[] paths)
	{
		import std.array;
		return buildNormalizedSplittedPath(paths).join('\\');
	}
	
	/// ditto
	string buildNormalizedWindowsPath()
	{
		import std.array;
		return buildNormalizedSplittedPath().join('\\');
	}
	
	/// ditto
	@system unittest
	{
		auto fs = FileSystem("ut\\./test");
		assert(fs.buildNormalizedWindowsPath() == "ut\\test");
		auto posixPath = fs.buildNormalizedWindowsPath("../path\\to/file");
		assert(posixPath == "ut\\path\\to\\file");
	}
	
	@system unittest
	{
		auto fs = FileSystem("ut/test\\");
		assert(fs.buildNormalizedWindowsPath() == "ut\\test");
		auto posixPath = fs.buildNormalizedWindowsPath("../path\\to/file");
		assert(posixPath == "ut\\path\\to\\file");
	}
	
	
	version (Windows)
	{
		/// In Windows
		alias buildNativePath           = buildWindowsPath;
		/// ditto
		alias buildNormalizedNativePath = buildNormalizedWindowsPath;
	}
	else
	{
		/// In Posix
		alias buildNativePath           = buildPosixPath;
		/// ditto
		alias buildNormalizedNativePath = buildNormalizedPosixPath;
	}
	
	/***************************************************************************
	 * パスが存在するか確認する
	 * 
	 * Params:
	 *     target = パス
	 */
	bool exists(string target = ".") const @safe
	{
		return existsImpl!true(target);
	}
	
	/// ditto
	private bool existsImpl(bool absConvert)(string target) const @safe
	{
		return .exists(absolutePath(target));
	}
	
	/// ditto
	private bool existsImpl(bool absConvert: false)(string target) const @safe
	{
		return .exists(target);
	}
	
	
	/***************************************************************************
	 * パスがファイルかどうか確認する
	 * 
	 * Params:
	 *     target = パス
	 */
	bool isFile(string target) const @safe
	{
		return isFileImpl!true(target);
	}
	
	/// ditto
	private bool isFileImpl(bool absConvert)(string target) const @safe
	{
		auto absTarget = absolutePath(target);
		return .exists(absTarget) && .isFile(absTarget);
	}
	
	/// ditto
	private bool isFileImpl(bool absConvert: false)(string target) const @safe
	{
		return .exists(target) && .isFile(target);
	}
	
	/***************************************************************************
	 * パスがファイルかどうか確認する
	 * 
	 * Params:
	 *     target = パス
	 */
	bool isDir(string target) const @safe
	{
		return isDirImpl!true(target);
	}
	
	/// ditto
	private bool isDirImpl(bool absConvert)(string target) const @safe
	{
		auto absTarget = absolutePath(target);
		return .exists(absTarget) && .isDir(absTarget);
	}
	
	/// ditto
	private bool isDirImpl(bool absConvert: false)(string target) const @safe
	{
		return .exists(target) && .isDir(target);
	}
	
	private bool makeDirImpl(bool absConvert)(string target, bool force, uint retrycnt) @safe
	{
		return makeDirImpl!false(absolutePath(target), force, retrycnt);
	}
	
	private bool makeDirImpl(bool absConvert: false)(string target, bool force, uint retrycnt) @trusted
	{
		if (isDir(target))
			return true;
		foreach (i; 0..retrycnt+1)
		{
			try
			{
				onCreating(target, i);
				if (!target.dirName.exists)
					mkdirRecurse(target.dirName);
				if (force && target.exists && !target.isFile)
				{
					try
					{
						std.file.remove(target);
					}
					catch (Exception e)
					{
						clearReadonly(target);
						std.file.remove(target);
					}
				}
				mkdir(target);
				enforce(target.isDir, "Cannot create directory");
				onCreated(target);
				return true;
			}
			catch (Exception e)
			{
				if (onCreateFailed && !onCreateFailed(target, e))
					return false;
			}
		}
		return !onCreateFailed || onCreateFailed(target, null);
	}
	
	/***************************************************************************
	 * ディレクトリを作成する
	 * 
	 * Params:
	 *     target   = パス
	 *     force    = 強制的に作成
	 *     retrycnt = リトライする回数
	 */
	void makeDir(string target, bool force = true, uint retrycnt = 5) @safe
	{
		makeDirImpl!true(target, force, retrycnt);
	}
	
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		
		fs.onCreating ~= (string target, uint i)
		{
			assert(i == 0);
			assert(target == fs.absolutePath("."));
		};
		fs.onCreated ~= (string target)
		{
			assert(target == fs.absolutePath("."));
		};
		fs.onCreateFailed ~= delegate bool (string target, Exception e)
		{
			assert(0);
		};
		fs.makeDir(".");
		// 2回目
		fs.onCreateFailed.clear();
		bool except;
		fs.onCreateFailed ~= delegate bool (string target, Exception e)
		{
			except = true;
			return false;
		};
		fs.makeDir(".");
		assert(!except);
		// 作れないフォルダを作る
		fs.onCreating.clear();
		fs.onCreated.clear();
		version (Windows)
		{
			fs.makeDir(":");
			assert(except);
		}
		else
		{
			// /や\0は作れないが、makeDirでは動かない
		}
	}
	
	/***************************************************************************
	 * エントリー一覧
	 */
	auto entries(SpanMode mode, bool followSymlink = true)
	{
		return .dirEntries(absolutePath(), mode, followSymlink);
	}
	
	/// ditto
	auto entries(string pattern, SpanMode mode = SpanMode.shallow, bool followSymlink = true)
	{
		return .dirEntries(absolutePath(), pattern, mode, followSymlink);
	}
	/// ditto
	auto entries(RE)(RE pattern, SpanMode mode = SpanMode.shallow, bool followSymlink = true)
	//if (isInstanceOf!(Regex, RE))
	if (is(typeof(std.regex.matchFirst("", pattern))))
	{
		import std.algorithm.iteration : filter;
		
		bool f(DirEntry de) { return cast(bool)match(de.name, pattern); }
		return filter!f(.dirEntries(absolutePath(), mode, followSymlink));
	}
	
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		fs.writeText("a/b/test1.txt", "Test");
		fs.writeText("a/c/test2.txt", "Test");
		fs.writeText("a/b/test3.txt", "Test");
		string[] files;
		foreach (de; fs.entries(SpanMode.depth))
		{
			files ~= de.name;
			assert(de.name.isAbsolute);
		}
		assert(files.length == 6);
		import std.algorithm: sort;
		files.sort();
		assert(fs.relativePath(files[0]).splitPath() == ["a"]);
		assert(fs.relativePath(files[1]).splitPath() == ["a", "b"]);
		assert(fs.relativePath(files[2]).splitPath() == ["a", "b", "test1.txt"]);
		assert(fs.relativePath(files[3]).splitPath() == ["a", "b", "test3.txt"]);
		assert(fs.relativePath(files[4]).splitPath() == ["a", "c"]);
		assert(fs.relativePath(files[5]).splitPath() == ["a", "c", "test2.txt"]);
		
		files = null;
		foreach (de; fs.entries(regex(r"test\d.txt"), SpanMode.depth))
		{
			files ~= de.name;
			assert(de.name.isAbsolute);
		}
		assert(files.length == 3);
		files.sort();
		assert(fs.relativePath(files[0]).splitPath() == ["a", "b", "test1.txt"]);
		assert(fs.relativePath(files[1]).splitPath() == ["a", "b", "test3.txt"]);
		assert(fs.relativePath(files[2]).splitPath() == ["a", "c", "test2.txt"]);
	}
	
	/***************************************************************************
	 * テキストファイルを書き出す
	 */
	void writeText(string filename, in char[] text)
	{
		writeTextImpl!true(filename, text);
	}
	
	private void writeTextImpl(bool absConvert)(string filename, in char[] text)
	{
		auto absFilename = absolutePath(filename);
		writeTextImpl!false(absFilename, text);
	}
	private void writeTextImpl(bool absConvert: false)(string filename, in char[] text)
	{
		makeDirImpl!false(filename.dirName, false, 0);
		std.file.write(filename, text);
	}
	
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		assert(!fs.isDir("a/b"));
		assert(!fs.isFile("a/b/test.txt"));
		fs.writeText("a/b/test.txt", "Test");
		assert(fs.isDir("a/b"));
		assert(fs.isFile("a/b/test.txt"));
	}
	
	/***************************************************************************
	 * テキストファイルを読み込む
	 */
	string readText(string filename)
	{
		return readTextImpl!true(filename);
	}
	
	private string readTextImpl(bool absConvert)(string filename)
	{
		auto absFilename = absolutePath(filename);
		return readTextImpl!false(absFilename);
	}
	private string readTextImpl(bool absConvert: false)(string filename)
	{
		if (!isFileImpl!false(filename))
			return null;
		return cast(typeof(return))std.file.read(filename);
	}
	
	
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		fs.writeText("a/b/test.txt", "Test");
		assert(fs.readText("a/b/test.txt") == "Test");
	}
	
	/***************************************************************************
	 * バイナリファイルを書き出す
	 */
	void writeBinary(string filename, in ubyte[] binary)
	{
		writeBinaryImpl!true(filename, binary);
	}
	
	private void writeBinaryImpl(bool absConvert)(string filename, in ubyte[] binary)
	{
		auto absFilename = absolutePath(filename);
		writeBinaryImpl!false(absFilename, binary);
	}
	private void writeBinaryImpl(bool absConvert: false)(string filename, in ubyte[] binary)
	{
		makeDirImpl!false(filename.dirName, false, 0);
		std.file.write(filename, binary);
	}
	
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		assert(!fs.isDir("a/b"));
		assert(!fs.isFile("a/b/test.dat"));
		fs.writeBinary("a/b/test.dat", cast(ubyte[])[1,2,3,4,5]);
		assert(fs.isDir("a/b"));
		assert(fs.isFile("a/b/test.dat"));
	}
	
	/***************************************************************************
	 * バイナリファイルを読み込む
	 */
	immutable(ubyte)[] readBinary(string filename)
	{
		return readBinaryImpl!true(filename);
	}
	
	private immutable(ubyte)[] readBinaryImpl(bool absConvert)(string filename)
	{
		auto absFilename = absolutePath(filename);
		return readBinaryImpl!false(absFilename);
	}
	private immutable(ubyte)[] readBinaryImpl(bool absConvert: false)(string filename)
	{
		if (!isFileImpl!false(filename))
			return null;
		return cast(typeof(return))std.file.read(filename);
	}
	
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		fs.writeBinary("a/b/test.dat", cast(ubyte[])[1,2,3,4,5]);
		assert(fs.readBinary("a/b/test.dat") == cast(ubyte[])[1,2,3,4,5]);
	}
	
	/***************************************************************************
	 * JSONファイルを書き出す
	 */
	void writeJson(T)(string filename, in T data, JSONOptions options = JSONOptions.none)
	{
		import voile.json;
		static assert(__traits(compiles, data.serializeToJsonString), "Unsupported type " ~ T.stringof);
		writeText(filename, data.serializeToJsonString(options));
	}
	
	/***************************************************************************
	 * JSONファイルを書き出す
	 */
	T readJson(T)(string filename)
	{
		import voile.json;
		T ret;
		static assert(__traits(compiles, ret.deserializeFromJsonString("")), "Unsupported type " ~ T.stringof);
		auto absFilename = absolutePath(filename);
		if (!isFileImpl!false(absFilename))
			return T.init;
		ret.deserializeFromJsonString(readTextImpl!false(absFilename));
		return ret;
	}
	
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		fs.writeJson!uint("a/b/test.json", 10);
		assert(fs.readJson!uint("a/b/test.json") == 10);
	}
	
	/// ditto
	@system unittest
	{
		import voile.json;
		auto fs = createDisposableDir("ut");
		static struct A
		{
			int a = 123;
			JSONValue json() const @property
			{
				JSONValue v;
				v.setValue("a", a);
				return v;
			}
			void json(JSONValue v) @property
			{
				assert(v.type == JSONType.object);
				a = v.getValue("a", 123);
			}
		}
		fs.writeJson("a/b/test.json", A(10));
		assert(fs.readJson!A("a/b/test.json") == A(10));
	}
	
	/***************************************************************************
	 * ファイルを新しく作成する
	 */
	File createFile(string filename)
	{
		auto absFilename = absolutePath(filename);
		makeDir(absFilename.dirName);
		if (!absFilename.dirName.exists)
			makeDir(absFilename);
		return File(absFilename, "w+");
	}
	
	/***************************************************************************
	 * ファイルを開く
	 * 
	 * ファイルがなければ新しく作成して開く
	 */
	File openFile(string filename, string attr = "r+")
	{
		auto absFilename = absolutePath(filename);
		if (!isFile(absFilename))
			return createFile(absFilename);
		return File(absFilename, attr);
	}
	
	
	private bool clearReadonlyImpl(bool absConvert)(string target) const @safe
	{
		if (target.isAbsolute)
			return clearReadonlyImpl!false(target);
		return clearReadonlyImpl!false(absolutePath(target, workDir.isAbsolute ? workDir : absolutePath(workDir)));
	}
	private bool clearReadonlyImpl(bool absConvert: false)(string target) const @safe
	{
		version (Windows)
		{
			import core.sys.windows.windows: FILE_ATTRIBUTE_READONLY;
			if (target.getAttributes() & FILE_ATTRIBUTE_READONLY)
				target.setAttributes(target.getAttributes() & ~FILE_ATTRIBUTE_READONLY);
			return true;
		}
		else version (Posix)
		{
			import core.sys.posix.sys.stat: S_IWUSR;
			enum writable = S_IWUSR;
			if ((target.getAttributes() & writable) != writable)
				target.setAttributes(target.getAttributes() | writable);
			return true;
		}
	}
	
	/*******************************************************************************
	 * 
	 */
	bool clearReadonly(string target) const
	{
		return clearReadonlyImpl!true(target);
	}
	
	
	private bool removeFilesImpl(bool absConvert)(string target, bool force, uint retrycnt) @safe
	{
		return removeFilesImpl!false(absolutePath(target), force, retrycnt);
	}
	private bool removeFilesImpl(bool absConvert: false)(string target, bool force, uint retrycnt) @trusted
	{
		if (!target.exists)
			return true;
		foreach (i; 0..retrycnt+1)
		{
			try
			{
				onRemoving(target, i);
				if (target.isDir)
				{
					try
					{
						rmdirRecurse(target);
					}
					catch (Exception e)
					{
						if (force)
						{
							foreach (de; dirEntries(target, SpanMode.depth))
								clearReadonlyImpl!false(de.name);
							rmdirRecurse(target);
						}
						else
						{
							throw e;
						}
					}
				}
				else
				{
					try
					{
						std.file.remove(target);
					}
					catch (Exception e)
					{
						if (force)
						{
							clearReadonlyImpl!false(target);
							std.file.remove(target);
						}
						else
						{
							throw e;
						}
					}
					enforce(!exists(target));
				}
				onRemoved(target);
				return true;
			}
			catch (Exception e)
			{
				if (onRemoveFailed && !onRemoveFailed(target, e))
					return false;
			}
		}
		return !onRemoveFailed || onRemoveFailed(target, null);
	}
	
	/*******************************************************************************
	 * 
	 */
	bool removeFiles(string target, bool force = true, uint retrycnt = 5) @safe
	{
		return removeFilesImpl!true(target, force, retrycnt);
	}
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		assert(!fs.isDir("a/b/c"));
		fs.makeDir("a/b/c");
		assert(fs.isDir("a/b/c"));
		
		fs.removeFiles("a");
		assert(!fs.isDir("a/b/c"));
		
		fs.makeDir("a/b/c");
		std.file.write(fs.absolutePath("a/b/test.txt"), "abcde");
		assert(fs.isFile("a/b/test.txt"));
		assert(.exists(buildPath(fs.workDir, "a/b/test.txt")));
		assert(cast(string)std.file.read(buildPath(fs.workDir, "a/b/test.txt")) == "abcde");
		fs.removeFiles("a");
		assert(!fs.isFile("a/b/test.txt"));
		assert(!fs.isDir("a/b/c"));
		assert(!fs.isDir("a/b"));
		assert(!fs.isDir("a"));
		
		assert(fs.isDir("."));
		fs.removeFiles(".");
		assert(!fs.isDir("."));
		assert(!.exists(fs.workDir));
	}
	
	/// ditto
	bool removeFiles(string targetDir, string blobFilter, bool force = true, uint retrycnt = 5)
	{
		auto absTarget = absolutePath(targetDir);
		foreach (i; 0.. retrycnt)
		{
			try
			{
				enforce(isDir(targetDir));
				foreach (de; dirEntries(absTarget, blobFilter, SpanMode.shallow))
				{
					if (!removeFilesImpl!false(de.name, force, retrycnt))
						return false;
				}
				return true;
			}
			catch (Exception e)
			{
				if (onRemoveFailed && !onRemoveFailed(absTarget, e))
					return false;
			}
		}
		return !onRemoveFailed || onRemoveFailed(absTarget, null);
	}
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		fs.makeDir("a/b/c");
		std.file.write(fs.absolutePath("a/b/test.txt"), "abcde");
		std.file.write(fs.absolutePath("a/b/test.csv"), "a,b,c,d,e");
		std.file.write(fs.absolutePath("a/test.txt"), "abcde");
		std.file.write(fs.absolutePath("a/test.csv"), "a,b,c,d,e");
		assert(fs.isFile("a/b/test.txt"));
		assert(fs.isFile("a/b/test.csv"));
		assert(fs.isFile("a/test.txt"));
		assert(fs.isFile("a/test.csv"));
		fs.removeFiles("a", "*.csv");
		assert(fs.isFile("a/b/test.txt"));
		assert(fs.isFile("a/b/test.csv"));
		assert(fs.isFile("a/test.txt"));
		assert(!fs.isFile("a/test.csv"));
		fs.removeFiles(".");
		assert(!.exists(fs.workDir));
	}
	
	private bool copyFileImpl(bool absConvert)(string src, string target, bool force, uint retrycnt)
	{
		auto absWork      = absolutePath();
		auto absSrc       = .absolutePath(src,    absWork).buildNormalizedPath();
		auto absTargetDir = .absolutePath(target, absWork).buildNormalizedPath();
		return copyFileImpl!false(absSrc, absTargetDir, force, retrycnt);
	}
	private bool copyFileImpl(bool absConvert: false)(string src, string target, bool force, uint retrycnt)
	{
		if (!target.dirName.exists)
			mkdirRecurse(target.dirName);
		enforce(src.exists && src.isFile);
		if (!target.dirName.exists)
		{
			foreach (i; 0..retrycnt+1)
			{
				try
				{
					makeDirImpl!false(target.dirName, force, 0);
					if (!target.dirName.exists)
						break;
				}
				catch (Exception e)
				{
					continue;
				}
			}
		}
		foreach (i; 0..retrycnt+1)
		{
			try
			{
				if (!target.dirName.exists)
				{
					makeDirImpl!false(target.dirName, force, 0);
					enforce(!target.dirName.exists, "Cannot create target parent directory for copy");
				}
				if (target.exists)
				{
					enforce(force, "File exists already");
					removeFilesImpl!false(target, force, 0);
				}
				enforce(force && !target.exists, "Cannot remove target file");
				std.file.copy(src, target);
				enforce(target.exists && target.isFile);
			}
			catch (Exception e)
			{
				if (onCopyFailed && !onCopyFailed(src, target, e))
					return false;
			}
		}
		return !onCopyFailed || onCopyFailed(src, target, null);
	}
	
	/***************************************************************************
	 * ファイルをコピーする
	 */
	bool copyFile(string srcFile, string targetFile, bool force = true, uint retrycnt = 5)
	{
		return copyFileImpl!true(srcFile, targetFile, force, retrycnt);
	}
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		assert(!fs.isFile("a/b/c.txt"));
		fs.writeText("a/b/c.txt", "aaaaa");
		fs.copyFile("a/b/c.txt", "a/c/c.txt");
		assert(fs.isFile("a/c/c.txt"));
	}
	
	private bool copyFilesImpl(bool absConvert)(string srcDir, string targetDir, bool force, uint retrycnt)
	{
		auto absWork      = absolutePath();
		auto absSrcDir    = .absolutePath(srcDir,    absWork).buildNormalizedPath();
		auto absTargetDir = .absolutePath(targetDir, absWork).buildNormalizedPath();
		return copyFilesImpl!false(absSrcDir, absTargetDir, force, retrycnt);
	}
	
	private bool copyFilesImpl(bool absConvert: false)(string srcDir, string targetDir, bool force, uint retrycnt)
	{
		foreach (de; dirEntries(srcDir, SpanMode.breadth))
		{
			auto srcPath = de.name.buildNormalizedPath;
			auto relPath = relativePath(srcPath, srcDir.buildNormalizedPath);
			auto targetPath = targetDir.buildNormalizedPath(relPath);
			if (de.name.isDir)
			{
				if (!makeDirImpl!false(targetPath, force, retrycnt))
					return false;
			}
			else
			{
				if (!copyFile(srcPath, targetPath, force, retrycnt))
					return false;
			}
		}
		return true;
	}
	
	private bool copyFilesImpl(bool absConvert)(
		string srcDir, string blobFilter, string targetDir, bool force, uint retrycnt)
	{
		auto absWork      = absolutePath();
		auto absSrcDir    = .absolutePath(srcDir,    absWork).buildNormalizedPath();
		auto absTargetDir = .absolutePath(targetDir, absWork).buildNormalizedPath();
		return copyFilesImpl!false(absSrcDir, blobFilter, absTargetDir, force, retrycnt);
	}
	
	private bool copyFilesImpl(bool absConvert: false)(
		string srcDir, string blobFilter, string targetDir, bool force, uint retrycnt)
	{
		foreach (de; dirEntries(srcDir, blobFilter, SpanMode.shallow))
		{
			auto srcPath = de.name.buildNormalizedPath;
			auto relPath = relativePath(srcPath, srcDir.buildNormalizedPath);
			auto targetPath = targetDir.buildNormalizedPath(relPath);
			if (de.name.isDir)
			{
				if (!copyFilesImpl!false(srcPath, targetPath, force, retrycnt))
					return false;
			}
			else
			{
				if (!copyFile(srcPath, targetPath, force, retrycnt))
					return false;
			}
		}
		return true;
	}
	
	/*******************************************************************************
	 * 
	 */
	bool copyFiles(string src, string target, bool force = true, uint retrycnt = 5)
	{
		if (isDir(src))
		{
			return copyFilesImpl!true(src, target, force, retrycnt);
		}
		else
		{
			return copyFileImpl!true(src, target, force, retrycnt);
		}
	}
	
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		assert(!fs.isFile("a/b/c.txt"));
		fs.writeText("a/b/c.txt", "aaaaa");
		fs.copyFiles("a/b/c.txt", "a/c/c.txt");
		assert(fs.isFile("a/c/c.txt"));
	}
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		assert(!fs.isFile("a/b/c.txt"));
		fs.writeText("a/b/c.txt", "aaaaa");
		fs.copyFiles("a/b", "a/c");
		assert(fs.isFile("a/c/c.txt"));
	}
	
	/*******************************************************************************
	 * 
	 */
	bool copyFiles(string srcDir, string blobFilter, string targetDir, bool force = true, uint retrycnt = 5)
	{
		return copyFilesImpl!true(srcDir, blobFilter, targetDir, force, retrycnt);
	}
	///
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		assert(!fs.isFile("a/b/c.txt"));
		assert(!fs.isFile("a/b/d.dat"));
		fs.writeText("a/b/c.txt", "aaaaa");
		fs.writeBinary("a/b/d.dat", [1,2,3]);
		fs.copyFiles("a/b", "*.txt", "a/c");
		assert(fs.isFile("a/c/c.txt"));
		assert(!fs.isFile("a/c/d.dat"));
	}
	
	
	private bool mirrorFilesImpl(bool absConvert)(string srcDir, string dstDir, bool force, uint retrycnt)
	{
		auto absWork      = absolutePath();
		auto absSrcDir    = .absolutePath(srcDir, absWork).buildNormalizedPath();
		auto absTargetDir = .absolutePath(dstDir, absWork).buildNormalizedPath();
		return mirrorFilesImpl!false(absSrcDir, absTargetDir, force, retrycnt);
	}
	
	private bool mirrorFilesImpl(bool absConvert: false)(string srcDir, string dstDir, bool force, uint retrycnt)
	{
		import std.algorithm, std.array;
		if (!dstDir.exists)
			return copyFiles(srcDir, dstDir);
		
		auto srcAbsPaths = dirEntries(srcDir, SpanMode.breadth).map!(a => a.name).array;
		auto dstAbsPaths = dirEntries(dstDir, SpanMode.breadth).map!(a => a.name).array;
		
		srcAbsPaths.sort!((a,b) => filenameCmp(a, b) < 0);
		dstAbsPaths.sort!((a,b) => filenameCmp(a, b) < 0);
		
		auto srcRelPaths = srcAbsPaths.map!(a => a.relativePath(srcDir)).array;
		auto dstRelPaths = dstAbsPaths.map!(a => a.relativePath(dstDir)).array;
		
		import std.stdio;
		size_t indexBefore, indexAfter;
		auto levPath = levenshteinDistanceAndPath(srcRelPaths, dstRelPaths)[1];
		
		bool mirCp(string srcPath, string dstPath)
		{
			if (srcPath.isDir)
			{
				if (!dstPath.exists)
					mkdirRecurse(dstPath);
				return true;
			}
			else
			{
				return copyFileImpl!false(srcPath, dstPath, force, retrycnt);
			}
		}
		bool mirRm(string dstPath)
		{
			return removeFilesImpl!false(dstPath, force, retrycnt);
		}
		
		foreach (editOp; levPath) final switch (editOp)
		{
		case EditOp.none:
			// ミラー元にもミラー先にもある更新対象のファイル/フォルダ
			if (srcAbsPaths[indexBefore].isFile)
			{
				// ファイルで、更新時間が違う場合のみコピーする
				if (srcAbsPaths[indexBefore].timeLastModified != dstAbsPaths[indexAfter].timeLastModified)
				{
					if (!mirCp(srcAbsPaths[indexBefore], dstAbsPaths[indexAfter]))
						return false;
				}
			}
			indexBefore++;
			indexAfter++;
			break;
		case EditOp.insert:
			// ミラー元になくてミラー先にある削除対象のファイル/フォルダ
			if (!mirRm(dstAbsPaths[indexAfter]))
				return false;
			indexAfter++;
			break;
		case EditOp.substitute:
			// ミラー元にあって、ミラー先にないコピー対象のファイル/フォルダ と ミラー元になくてミラー先にある削除対象のファイル/フォルダ
			if (!mirCp(srcAbsPaths[indexBefore], dstDir.buildPath(srcRelPaths[indexBefore]))
			 || !mirRm(dstAbsPaths[indexAfter]))
				return false;
			indexBefore++;
			indexAfter++;
			break;
		case EditOp.remove:
			// ミラー元にあって、ミラー先にないコピー対象のファイル/フォルダ
			if (!mirCp(srcAbsPaths[indexBefore], dstDir.buildPath(srcRelPaths[indexBefore])))
				return false;
			indexBefore++;
			break;
		}
		return true;
	}
	
	/*******************************************************************************
	 * ファイルをミラーリングする
	 */
	bool mirrorFiles(string srcDir, string dstDir, bool force = true, uint retrycnt = 5)
	{
		return mirrorFilesImpl!true(srcDir, dstDir, force, retrycnt);
	}
	
	
	
	//--------------------------------------------------------------------------
	// 
	private bool moveFilesImpl(bool absConvert)(string src, string dst, bool force, bool retrycnt)
	{
		auto absWork      = absolutePath();
		auto absSrcDir    = .absolutePath(src, absWork).buildNormalizedPath();
		auto absTargetDir = .absolutePath(dst, absWork).buildNormalizedPath();
		return moveFilesImpl!false(absSrcDir, absTargetDir, force, retrycnt);
	}
	// 
	private bool moveFilesImpl(bool absConvert: false)(string src, string dst, bool force, bool retrycnt)
	{
		if (!src.exists)
			return true;
		version (Windows)
		{
			if (src.driveName == dst.driveName)
			{
				// ドライブが同一ならWinAPIのMoveFileを利用する
				if (!removeFilesImpl!false(dst, force, retrycnt))
					return false;
				import core.sys.windows.windows;
				import std.windows.syserror;
				import std.utf;
				auto movSrc = (`\\?\`~src).toUTF16z();
				auto movDst = (`\\?\`~dst).toUTF16z();
				foreach (Unused; 0..retrycnt)
				{
					try
					{
						enforce(!dst.exists);
						MoveFileW(movSrc, movDst).enforce(GetLastError().sysErrorString());
						return true;
					}
					catch (Exception e)
					{
						import core.thread;
						Thread.sleep(10.msecs);
					}
				}
				// WinAPIが使用できない場合はファイルをミラーリングして元のファイルを削除する
				if (!mirrorFilesImpl!false(src, dst, force, retrycnt)
				 || !removeFilesImpl!false(src, force, retrycnt))
					return false;
			}
			else
			{
				// ドライブが異なる場合、ミラーリングして元のファイルを削除する
				if (!mirrorFilesImpl!false(src, dst, force, retrycnt)
				 || !removeFilesImpl!false(src, force, retrycnt))
					return false;
			}
		}
		else
		{
			foreach (Unused; 0..retrycnt)
			{
				try
				{
					enforce(!dst.exists);
					std.file.rename(src, dst);
					return true;
				}
				catch (Exception e)
				{
					import core.thread;
					Thread.sleep(10.msecs);
				}
			}
			// リネームに失敗した場合はミラーリングして元のファイルを削除する
			if (!mirrorFilesImpl!false(src, dst, force, retrycnt)
			 || !removeFilesImpl!false(src, force, retrycnt))
				return false;
		}
		return true;
	}
	
	/*******************************************************************************
	 * ファイルを移動する
	 */
	bool moveFiles(string src, string dst, bool force = true, bool retrycnt = true)
	{
		return moveFilesImpl!true(src, dst, force, retrycnt);
	}
	
	/*******************************************************************************
	 * シンボリックリンクを作成する
	 */
	void symlink(in char[] target, in char[] link)
	{
		auto isAbs = isAbsolute(cast(immutable)target);
		auto linkPath = absolutePath(cast(immutable)link);
		auto targetPath = isAbs
			? buildNormalizedNativePath(cast(immutable)target)
			: .relativePath(absolutePath(cast(immutable)target), linkPath.dirName);
		version (Windows)
		{
			import core.sys.windows.windows;
			import core.sys.windows.winbase;
			import std.utf: toUTF16z;
			import std.windows.syserror;
			immutable flg = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
				| (isDir(cast(immutable)target) ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0);
			CreateSymbolicLinkW(toUTF16z(r"\\?\" ~ linkPath),
				toUTF16z(isAbs ? r"\\?\" ~ targetPath : targetPath), flg)
				.enforce(GetLastError().sysErrorString());
		}
		else
		{
			std.file.symlink(targetPath, linkPath);
		}
	}
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		fs.writeText("test1.txt", "1");
		fs.symlink("test1.txt", "test2.txt");
		assert(fs.readText("test2.txt") == "1");
		fs.writeText("test2.txt", "2");
		assert(fs.readText("test1.txt") == "2");
	}
	
	/*******************************************************************************
	 * シンボリックリンクの実パスを得る
	 */
	string readLink(in char[] link)
	{
		auto linkPath = absolutePath(cast(immutable)link);
		version (Windows)
		{
			import core.sys.windows.windows;
			import std.utf: toUTF16z, toUTF8;
			import std.string: chompPrefix, chomp;
			import std.windows.syserror;
			enum FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
			enum FILE_FLAG_BACKUP_SEMANTICS   = 0x02000000;
			enum FSCTL_GET_REPARSE_POINT      = 0x000900A8;
			enum IO_REPARSE_TAG_SYMLINK       = 0xA000000C;
			struct REPARSE_DATA_BUFFER
			{
				ULONG  ReparseTag;
				USHORT ReparseDataLength;
				USHORT Reserved;
				union
				{
					struct SymbolicLinkReparseBuffer
					{
						USHORT SubstituteNameOffset;
						USHORT SubstituteNameLength;
						USHORT PrintNameOffset;
						USHORT PrintNameLength;
						ULONG  Flags;
						WCHAR[1] PathBuffer;
					}
					SymbolicLinkReparseBuffer symbolicLinkReparseBuffer;
					struct MountPointReparseBuffer
					{
						USHORT SubstituteNameOffset;
						USHORT SubstituteNameLength;
						USHORT PrintNameOffset;
						USHORT PrintNameLength;
						WCHAR[1] PathBuffer;
					}
					MountPointReparseBuffer mountPointReparseBuffer;
					struct GenericReparseBuffer
					{
						UCHAR[1] DataBuffer;
					}
					GenericReparseBuffer genericReparseBuffer;
				}
			}
			auto hLink = CreateFileW(toUTF16z(r"\\?\" ~ linkPath), 0, 0, NULL, OPEN_EXISTING,
				FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL)
				.enforce(GetLastError().sysErrorString());
			scope (exit)
				CloseHandle(hLink);
			auto buflen = 0xffff;
			auto buf = new ubyte[buflen];
			DWORD pathlen;
			DeviceIoControl(hLink, FSCTL_GET_REPARSE_POINT, NULL, 0, buf.ptr, buflen, &pathlen, NULL);
			auto reparseData = cast(REPARSE_DATA_BUFFER*)buf.ptr;
			if (reparseData.ReparseTag != IO_REPARSE_TAG_SYMLINK)
				return null;
			
			return toUTF8(reparseData.symbolicLinkReparseBuffer.PathBuffer.ptr[
				0..reparseData.symbolicLinkReparseBuffer.SubstituteNameLength/wchar.sizeof])
				.chompPrefix(r"\\?\")
				.chomp(r"\??\");
		}
		else
		{
			return std.file.readLink(linkPath);
		}
	}
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		fs.writeText("test1.txt", "1");
		fs.symlink("test1.txt", "test2.txt");
		fs.symlink(fs.absolutePath("test1.txt"), "test3.txt");
		assert(fs.readLink("test2.txt") == "test1.txt");
		assert(fs.readLink("test3.txt") == fs.absolutePath("test1.txt"));
	}
	
	//--------------------------------------------------------------------------
	// タイムスタンプ取得・設定の実装
	private void setTimeStampImpl(bool absConvert)(string target, SysTime accessTime, SysTime modificationTime)
	{
		setTimeStampImpl!false(absolutePath(target), accessTime, modificationTime);
	}
	// 
	private void setTimeStampImpl(bool absConvert: false)(string target, SysTime accessTime, SysTime modificationTime)
	{
		setTimes(target, accessTime, modificationTime);
	}
	// 
	private void getTimeStampImpl(bool absConvert)(string target, out SysTime accessTime, out SysTime modificationTime)
	{
		getTimeStampImpl!false(absolutePath(target), accessTime, modificationTime);
	}
	// 
	private void getTimeStampImpl(bool absConvert: false)(string target,
		out SysTime accessTime, out SysTime modificationTime)
	{
		getTimes(target, accessTime, modificationTime);
	}
	
	
	/*******************************************************************************
	 * タイムスタンプを変更/取得する
	 */
	void setTimeStamp(string target, SysTime accessTime, SysTime modificationTime)
	{
		setTimeStampImpl!true(target, accessTime, modificationTime);
	}
	/// ditto
	void setTimeStamp(string target, SysTime modificationTime)
	{
		setTimeStampImpl!true(target, modificationTime, modificationTime);
	}
	/// ditto
	void setTimeStamp(string target, DateTime accessTime, DateTime modificationTime)
	{
		setTimeStampImpl!true(target, SysTime(accessTime), SysTime(modificationTime));
	}
	/// ditto
	void setTimeStamp(string target, DateTime modificationTime)
	{
		setTimeStampImpl!true(target, SysTime(modificationTime), SysTime(modificationTime));
	}
	/// ditto
	void getTimeStamp(string target, out SysTime accessTime, out SysTime modificationTime)
	{
		getTimeStampImpl!true(target, accessTime, modificationTime);
	}
	/// ditto
	void getTimeStamp(string target, out SysTime modificationTime)
	{
		SysTime accessTime;
		getTimeStampImpl!true(target, accessTime, modificationTime);
	}
	/// ditto
	void getTimeStamp(string target, out DateTime accessTime, out DateTime modificationTime)
	{
		SysTime accessTimeTmp, modificationTimeTmp;
		getTimeStampImpl!true(target, accessTimeTmp, modificationTimeTmp);
		accessTime       = cast(DateTime)accessTimeTmp;
		modificationTime = cast(DateTime)modificationTimeTmp;
	}
	/// ditto
	void getTimeStamp(string target, out DateTime modificationTime)
	{
		SysTime accessTimeTmp, modificationTimeTmp;
		getTimeStampImpl!true(target, accessTimeTmp, modificationTimeTmp);
		modificationTime = cast(DateTime)modificationTimeTmp;
	}
	/// ditto
	SysTime getTimeStamp(string target)
	{
		SysTime accessTime, modificationTime;
		getTimeStampImpl!true(target, accessTime, modificationTime);
		return modificationTime;
	}
	
	@system unittest
	{
		auto fs = createDisposableDir("ut");
		auto fs2 = createDisposableDir("ut");
		auto timMod = Clock.currTime;
		auto timAcc = timMod;
		fs.writeText(   "src/test1-1.txt", "1");
		fs.setTimeStamp("src/test1-1.txt", timAcc, timMod+1.msecs);
		fs.writeText(   "src/test1-2.txt", "1");
		fs.setTimeStamp("src/test1-2.txt", timAcc, timMod+1.msecs);
		fs.writeText(   "src/test2-1.txt", "2");
		fs.setTimeStamp("src/test2-1.txt", timAcc, timMod+2.msecs);
		fs.writeText(   "src/test2-2.txt", "2");
		fs.setTimeStamp("src/test2-2.txt", timAcc, timMod+2.msecs);
		fs.copyFile(    "src/test2-1.txt", fs2.relativePath("dst/test2-1.txt"));
		fs.copyFile(    "src/test2-2.txt", fs2.relativePath("dst/test2-2.txt"));
		fs.writeText(   "src/test4.txt", "4");
		fs.setTimeStamp("src/test4.txt", timAcc, timMod+4.msecs);
		fs.writeText(   "dst/test3.txt", "3");
		fs.setTimeStamp("dst/test3.txt", timAcc, timMod+3.msecs);
		fs.writeText(   "dst/test4.txt", "4x");
		fs.setTimeStamp("dst/test4.txt", timAcc, timMod+8.msecs);
		fs.writeText(   "src/test5-11.txt", "5");
		fs.setTimeStamp("src/test5-11.txt", timAcc, timMod+10.msecs);
		fs.writeText(   "src/test5-21.txt", "5");
		fs.setTimeStamp("src/test5-21.txt", timAcc, timMod+10.msecs);
		fs.writeText(   "dst/test5-12.txt", "5");
		fs.setTimeStamp("dst/test5-12.txt", timAcc, timMod+10.msecs);
		fs.writeText(   "dst/test5-22.txt", "5");
		fs.setTimeStamp("dst/test5-22.txt", timAcc, timMod+10.msecs);
		fs.mirrorFiles( "src", "dst");
		assert( fs.workDir.buildPath("src/test1-1.txt").exists);
		assert( fs.workDir.buildPath("src/test1-2.txt").exists);
		assert( fs.workDir.buildPath("src/test2-1.txt").exists);
		assert( fs.workDir.buildPath("src/test2-2.txt").exists);
		assert(!fs.workDir.buildPath("src/test3.txt").exists);
		assert( fs.workDir.buildPath("src/test4.txt").exists);
		assert( fs.workDir.buildPath("dst/test1-1.txt").exists);
		assert( fs.workDir.buildPath("dst/test1-2.txt").exists);
		assert( fs.workDir.buildPath("dst/test2-1.txt").exists);
		assert( fs.workDir.buildPath("dst/test2-2.txt").exists);
		assert(!fs.workDir.buildPath("dst/test3.txt").exists);
		assert( fs.workDir.buildPath("dst/test4.txt").exists);
		assert((cast(string)std.file.read(fs.workDir.buildPath("dst/test1-1.txt"))) == "1");
		assert((cast(string)std.file.read(fs.workDir.buildPath("dst/test1-2.txt"))) == "1");
		assert((cast(string)std.file.read(fs.workDir.buildPath("dst/test2-1.txt"))) == "2");
		assert((cast(string)std.file.read(fs.workDir.buildPath("dst/test2-2.txt"))) == "2");
		assert((cast(string)std.file.read(fs.workDir.buildPath("dst/test4.txt"))) == "4");
	}
	
	
	/***************************************************************************
	 * パスを検索する
	 */
	string searchPath(in char[] executable, in string[] additional = null) const @trusted
	{
		if (executable.exists)
			return executable.dup;
		import std.algorithm : splitter;
		import std.conv;
		import std.process: environment;
		string execFileName = executable.idup;
		version (Windows)
			execFileName = execFileName.setExtension(".exe");
		string execPath;
		if (execFileName.isAbsolute())
			return execFileName;
		foreach (dir; additional)
		{
			execPath = buildPath(dir, execFileName);
			if (execPath.exists)
				return execPath;
		}
		
		execPath = buildPath(thisExePath.dirName, execFileName);
		if (execPath.exists)
			return execPath;
		
		execPath = buildPath(workDir, execFileName);
		if (execPath.exists)
			return execPath;
		
		auto paths = environment.get("PATH", environment.get("Path", environment.get("path")));
		if (paths == null)
			return null;
		
		foreach (dir; splitter(to!string(paths), pathSeparator))
		{
			execPath = buildPath(dir, execFileName);
			if (execPath.exists)
				return execPath;
		}
		
		return null;
	}
	
	/***************************************************************************
	 * プロセスを実行する
	 */
	auto spawnProcess(string[] args, string[string] env = null,
	                  std.process.Config cfg = std.process.Config.none)
	{
		import std.algorithm, std.array;
		makeDir(".");
		string[] searchPaths;
		if (auto paths = env.get("PATH", env.get("Path", env.get("path", string.init))))
			searchPaths = std.algorithm.splitter(paths, pathSeparator).array;
		return .spawnProcess([searchPath(args[0], searchPaths)] ~ args[1..$],
		                      stdin, stdout, stderr, env, cfg, workDir);
	}
	
	/// ditto
	auto spawnProcess(string[] args, File fin, File fout, File ferr,
	                  string[string] env = null,
	                  std.process.Config cfg = std.process.Config.suppressConsole)
	{
		import std.algorithm, std.array;
		makeDir(".");
		string[] searchPaths;
		if (auto paths = env.get("PATH", env.get("Path", env.get("path", string.init))))
			searchPaths = std.algorithm.splitter(paths, pathSeparator).array;
		return .spawnProcess([searchPath(args[0], searchPaths)] ~ args[1..$],
		                      fin  is File.init ? nullFile("r") : fin,
		                      fout is File.init ? nullFile("w") : fout,
		                      ferr is File.init ? nullFile("w") : ferr,
		                      env, cfg, workDir);
	}
	
	/// ditto
	auto spawnProcess(string[] args, Pipe pin, Pipe pout, Pipe perr,
	                  string[string] env = null,
	                  std.process.Config cfg = std.process.Config.suppressConsole)
	{
		import std.algorithm, std.array;
		makeDir(".");
		string[] searchPaths;
		if (auto paths = env.get("PATH", env.get("Path", env.get("path", string.init))))
			searchPaths = std.algorithm.splitter(paths, pathSeparator).array;
		return .spawnProcess([searchPath(args[0], searchPaths)] ~ args[1..$],
		                     pin  is Pipe.init ? nullFile("r") : pin.readEnd,
		                     pout is Pipe.init ? nullFile("w") : pout.writeEnd,
		                     perr is Pipe.init ? nullFile("w") : perr.writeEnd,
		                     env, cfg, workDir);
	}
	
	/// ditto
	auto pipeProcess(string[] args, string[string] env = null,
	                 std.process.Config cfg = std.process.Config.suppressConsole)
	{
		import std.algorithm, std.array;
		makeDir(".");
		string[] searchPaths;
		if (auto paths = env.get("PATH", env.get("Path", env.get("path", string.init))))
			searchPaths = std.algorithm.splitter(paths, pathSeparator).array;
		return .pipeProcess([searchPath(args[0], searchPaths)] ~ args[1..$],
		                     Redirect.all, env, cfg, workDir);
	}
	
	/// ditto
	auto execute(string[] args, string[string] env = null,
	             std.process.Config cfg = std.process.Config.suppressConsole)
	{
		import std.algorithm, std.array;
		makeDir(".");
		string[] searchPaths;
		if (auto paths = env.get("PATH", env.get("Path", env.get("path", string.init))))
			searchPaths = std.algorithm.splitter(paths, pathSeparator).array;
		return .execute([searchPath(args[0], searchPaths)] ~ args[1..$],
		                 env, cfg, size_t.max, workDir);
	}
	
	///
	@system unittest
	{
		import std.string;
		auto fs = createDisposableDir("ut");
		auto pipeo = pipe();
		version (Windows)
		{
			auto cmd = ["cmd", "/C", "echo xxx"];
		}
		else
		{
			auto cmd = ["bash", "-c", "echo xxx"];
		}
		auto pid = fs.spawnProcess(cmd, Pipe.init, pipeo, pipeo, ["Path": fs.absolutePath]);
		pid.wait();
		auto xxx = pipeo.readEnd().readln;
		assert(xxx.chomp == "xxx");
	}
	
	///
	@system unittest
	{
		import std.string;
		auto fs = createDisposableDir("ut");
		auto pipeo = pipe();
		version (Windows)
		{
			auto cmd = ["cmd", "/C", "echo xxx"];
		}
		else
		{
			auto cmd = ["bash", "-c", "echo xxx"];
		}
		auto pipe = fs.pipeProcess(cmd, ["Path": fs.absolutePath]);
		pipe.pid.wait();
		auto xxx = pipe.stdout().readln;
		assert(xxx.chomp == "xxx");
	}
	
	///
	@system unittest
	{
		import std.string;
		auto fs = createDisposableDir("ut");
		auto tout = fs.createFile("test.txt");
		version (Windows)
		{
			auto cmd = ["cmd", "/C", "echo xxx"];
		}
		else
		{
			auto cmd = ["bash", "-c", "echo xxx"];
		}
		auto pid = fs.spawnProcess(cmd, File.init, tout, File.init, ["Path": fs.absolutePath]);
		pid.wait();
		tout.close();
		auto result = fs.readText("test.txt");
		assert(result.chomp == "xxx");
	}
	
	///
	@system unittest
	{
		import std.string;
		auto fs = createDisposableDir("ut");
		version (Windows)
		{
			auto cmd = ["cmd", "/C", "echo xxx"];
		}
		else
		{
			auto cmd = ["bash", "-c", "echo xxx"];
		}
		auto result = fs.execute(cmd, ["Path": fs.absolutePath]);
		assert(result.output.chomp == "xxx");
	}
}
/// コピー禁止とムーブ、インスタンス削除の例
@system unittest
{
	import std.algorithm: move;
	string[] msgDestroyed;
	{
		FileSystem fs1 = FileSystem(".");
		FileSystem fs2;
		static assert(!__traits(compiles, fs2 = fs1));
		static assert(__traits(compiles, fs2 = fs1.move()));
		fs1.onDestroyed ~= (string x) { msgDestroyed ~= "fs1"; };
		fs2.onDestroyed ~= (string x) { msgDestroyed ~= "fs2"; };
	}
	assert(msgDestroyed == ["fs1"]);
}

/*******************************************************************************
 * 一時ディレクトリを作成し、作成したディレクトリのFileSystemを返す
 */
FileSystem createTempDir(string basePath = tempDir, string prefix = "voile-", uint retrycnt = 5) @safe
{
	import std.uuid;
	import std.algorithm: move;
	import core.thread: Thread, msecs;
	FileSystem ret;
	foreach (tryCnt; 0..retrycnt)
	{
		try
		{
			auto id = randomUUID().toString();
			auto newpath = basePath.buildPath(prefix ~ id);
			if (newpath.exists)
				continue;
			ret.workDir = newpath;
			ret.makeDir(".", true, retrycnt);
			break;
		}
		catch (Exception e)
		{
			continue;
		}
	}
	ret.exists.enforce();
	return ret.move();
}

/*******************************************************************************
 * 使い捨ての一時ディレクトリを作成
 * 
 * 作成したディレクトリのFileSystemを返す。返されたFileSystemは、インスタンスの破棄時に削除される。
 */
FileSystem createDisposableDir(string basePath = tempDir, string prefix = "voile-", uint retrycnt = 5) @safe
{
	import std.algorithm: move;
	auto fs = createTempDir(basePath, prefix, retrycnt);
	(() @trusted => fs.onDestroyed ~= (string dir)
	{
		if (.exists(dir))
			cast(void)FileSystem(dir).removeFiles(".", true, retrycnt);
	})();
	return fs.move();
}

///
@safe unittest
{
	string dir;
	{
		auto fs = createDisposableDir("ut");
		dir = fs.workDir;
	}
	assert(!dir.exists);
}
