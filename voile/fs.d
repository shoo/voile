module voile.fs;

import std.file, std.path, std.exception, std.stdio, std.datetime;
import std.process;
import voile.handler;

/*******************************************************************************
 * ファイルシステムの操作に関するヘルパ
 */
struct FileSystem
{
	///
	string workDir = ".";
	
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
	
	/***************************************************************************
	 * 絶対パスに変換する
	 * 
	 * Params:
	 *     target = 変換したい相対パス(何も指定しないとworkDirの絶対パスが返る)
	 *     base   = 基準となるパス(このパスの基準はworkDir)
	 */
	string absolutePath() const @safe
	{
		if (workDir.isAbsolute)
			return workDir.buildNormalizedPath();
		return .absolutePath(workDir).buildNormalizedPath;
	}
	/// ditto
	string absolutePath(string target) const @safe
	{
		if (target.isAbsolute)
			return target.buildNormalizedPath();
		return .absolutePath(target, absolutePath()).buildNormalizedPath;
	}
	/// ditto
	string absolutePath(string target, string base) const @safe
	{
		if (target.isAbsolute)
			return target.buildNormalizedPath();
		return .absolutePath(target, this.absolutePath(base)).buildNormalizedPath();
	}
	
	@safe unittest
	{
		auto fs = FileSystem("ut");
		assert(fs.absolutePath(".") == .absolutePath("ut").buildNormalizedPath());
	}
	
	/*******************************************************************************
	 * 実際のパス名に修正する
	 */
	string actualPath(string path = ".")
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
			SHGetFileInfoW(result.buildPath(p).toUTF16z(), 0, &info, info.sizeof, SHGFI_DISPLAYNAME);
			result = result.buildPath(toUTF8(info.szDisplayName.ptr[0..wcslen(info.szDisplayName.ptr)]));
		}
		return result;
	}
	@system unittest
	{
		auto fs = FileSystem("C:/");
		assert(fs.actualPath(r"wInDoWs") == r"C:\Windows");
	}
	
	/***************************************************************************
	 * パスが存在するか確認する
	 * 
	 * Params:
	 *     target = パス
	 */
	bool exists(string target) const @safe
	{
		return .exists(absolutePath(target));
	}
	
	
	/***************************************************************************
	 * パスがファイルかどうか確認する
	 * 
	 * Params:
	 *     target = パス
	 */
	bool isFile(string target) const @safe
	{
		auto absTarget = absolutePath(target);
		return .exists(absTarget) && .isFile(absTarget);
	}
	
	/***************************************************************************
	 * パスがファイルかどうか確認する
	 * 
	 * Params:
	 *     target = パス
	 */
	bool isDir(string target) const @safe
	{
		auto absTarget = absolutePath(target);
		return .exists(absTarget) && .isDir(absTarget);
	}
	
	private bool makeDirImpl(bool absConvert)(string target, bool force, uint retrycnt)
	{
		return makeDirImpl!false(absolutePath(target), force, retrycnt);
	}
	
	private bool makeDirImpl(bool absConvert: false)(string target, bool force, uint retrycnt)
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
	void makeDir(string target, bool force = true, uint retrycnt = 5)
	{
		makeDirImpl!true(target, force, retrycnt);
	}
	
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
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
		fs.makeDir(":");
		assert(except);
	}
	
	/***************************************************************************
	 * テキストファイルを書き出す
	 */
	void writeText(string filename, in char[] text)
	{
		auto absFilename = absolutePath(filename);
		makeDirImpl!false(absFilename.dirName, false, 0);
		std.file.write(absFilename, text);
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
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
		auto absFilename = absolutePath(filename);
		if (!isFile(absFilename))
			return null;
		return cast(typeof(return))std.file.read(absFilename);
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		fs.writeText("a/b/test.txt", "Test");
		assert(fs.readText("a/b/test.txt") == "Test");
	}
	
	/***************************************************************************
	 * バイナリファイルを書き出す
	 */
	void writeBinary(string filename, in ubyte[] binary)
	{
		auto absFilename = absolutePath(filename);
		makeDirImpl!false(absFilename.dirName, false, 0);
		std.file.write(absFilename, binary);
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
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
		auto absFilename = absolutePath(filename);
		if (!isFile(absFilename))
			return null;
		return cast(typeof(return))std.file.read(absFilename);
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		fs.writeBinary("a/b/test.dat", cast(ubyte[])[1,2,3,4,5]);
		assert(fs.readBinary("a/b/test.dat") == cast(ubyte[])[1,2,3,4,5]);
	}
	
	/***************************************************************************
	 * JSONファイルを書き出す
	 */
	void writeJson(T)(string filename, in T data)
	{
		import voile.json, std.json;
		static assert(__traits(compiles, data.json), "Unsupported type " ~ T.stringof);
		writeText(filename, data.json.toPrettyString);
	}
	
	/***************************************************************************
	 * JSONファイルを書き出す
	 */
	T readJson(T)(string filename)
	{
		import voile.json, std.json;
		T ret;
		auto absFilename = absolutePath(filename);
		if (!absFilename.isFile)
			return T.init;
		auto jv = parseJSON(readText(filename));
		static assert(__traits(compiles, fromJson!T(jv, ret)), "Unsupported type " ~ T.stringof);
		enforce(fromJson(jv, ret));
		return ret;
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		fs.writeJson!uint("a/b/test.json", 10);
		assert(fs.readJson!uint("a/b/test.json") == 10);
	}
	
	/// ditto
	@system unittest
	{
		import voile.json, std.json;
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
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
				assert(v.type == JSON_TYPE.OBJECT);
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
			import core.sys.posix.stat: S_IWUSR;
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
	
	
	private bool removeFilesImpl(bool absConvert)(string target, bool force, uint retrycnt)
	{
		return removeFilesImpl!false(absolutePath(target), force, retrycnt);
	}
	private bool removeFilesImpl(bool absConvert: false)(string target, bool force, uint retrycnt)
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
	bool removeFiles(string target, bool force = true, uint retrycnt = 5)
	{
		return removeFilesImpl!true(target, force, retrycnt);
	}
	@system unittest
	{
		auto fs = FileSystem("ut");
		assert(!fs.isDir("a/b/c"));
		fs.makeDir("a/b/c");
		assert(fs.isDir("a/b/c"));
		
		fs.removeFiles("a");
		assert(!fs.isDir("a/b/c"));
		
		fs.makeDir("a/b/c");
		std.file.write(fs.absolutePath("a/b/test.txt"), "abcde");
		assert(fs.isFile("a/b/test.txt"));
		assert(.exists("ut/a/b/test.txt"));
		assert(cast(string)std.file.read("ut/a/b/test.txt") == "abcde");
		fs.removeFiles("a");
		assert(!fs.isFile("a/b/test.txt"));
		assert(!fs.isDir("a/b/c"));
		assert(!fs.isDir("a/b"));
		assert(!fs.isDir("a"));
		
		assert(fs.isDir("."));
		fs.removeFiles(".");
		assert(!fs.isDir("."));
		assert(!.exists("ut"));
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
		auto fs = FileSystem("ut");
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
		assert(!.exists("ut"));
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
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
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
		return copyFilesImpl!false(absSrcDir, absTargetDir, force, retrycnt);
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
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		assert(!fs.isFile("a/b/c.txt"));
		fs.writeText("a/b/c.txt", "aaaaa");
		fs.copyFiles("a/b/c.txt", "a/c/c.txt");
		assert(fs.isFile("a/c/c.txt"));
	}
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
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
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		assert(!fs.isFile("a/b/c.txt"));
		assert(!fs.isFile("a/b/d.dat"));
		fs.writeText("a/b/c.txt", "aaaaa");
		fs.writeBinary("a/b/c.txt", [1,2,3]);
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
		import std.algorithm, std.file, std.path, std.array;
		if (!dstDir.exists)
			return copyFiles(srcDir, dstDir);
		auto srcAbsPaths = dirEntries(srcDir, SpanMode.breadth).map!(a => a.name).array;
		auto dstAbsPaths = dirEntries(dstDir, SpanMode.breadth).map!(a => a.name).array;
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
		import std.file, std.path;
		if (!src.exists)
			return true;
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
		return true;
	}
	
	/*******************************************************************************
	 * ファイルを移動する
	 */
	bool moveFiles(string src, string dst, bool force = true, bool retrycnt = true)
	{
		return moveFilesImpl!true(src, dst, force, retrycnt);
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
	private void getTimeStampImpl(bool absConvert: false)(string target, out SysTime accessTime, out SysTime modificationTime)
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
		mkdirRecurse("ut/filestest/src");
		mkdirRecurse("ut/filestest/dst");
		auto fs = FileSystem("ut");
		scope (exit)
			fs.removeFiles(".");
		auto timMod = Clock.currTime;
		auto timAcc = timMod;
		fs.writeText(   "filestest/src/test1-1.txt", "1");
		fs.setTimeStamp("filestest/src/test1-1.txt", timAcc, timMod+1.msecs);
		fs.writeText(   "filestest/src/test1-2.txt", "1");
		fs.setTimeStamp("filestest/src/test1-2.txt", timAcc, timMod+1.msecs);
		fs.writeText(   "filestest/src/test2-1.txt", "2");
		fs.setTimeStamp("filestest/src/test2-1.txt", timAcc, timMod+2.msecs);
		fs.writeText(   "filestest/src/test2-2.txt", "2");
		fs.setTimeStamp("filestest/src/test2-2.txt", timAcc, timMod+2.msecs);
		fs.copyFile(    "filestest/src/test2-1.txt", "testcase/filestest/dst/test2-1.txt");
		fs.copyFile(    "filestest/src/test2-2.txt", "testcase/filestest/dst/test2-2.txt");
		fs.writeText(   "filestest/src/test4.txt", "4");
		fs.setTimeStamp("filestest/src/test4.txt", timAcc, timMod+4.msecs);
		fs.writeText(   "filestest/dst/test3.txt", "3");
		fs.setTimeStamp("filestest/dst/test3.txt", timAcc, timMod+3.msecs);
		fs.writeText(   "filestest/dst/test4.txt", "4x");
		fs.setTimeStamp("filestest/dst/test4.txt", timAcc, timMod+8.msecs);
		fs.writeText(   "filestest/src/test5-11.txt", "5");
		fs.setTimeStamp("filestest/src/test5-11.txt", timAcc, timMod+10.msecs);
		fs.writeText(   "filestest/src/test5-21.txt", "5");
		fs.setTimeStamp("filestest/src/test5-21.txt", timAcc, timMod+10.msecs);
		fs.writeText(   "filestest/dst/test5-12.txt", "5");
		fs.setTimeStamp("filestest/dst/test5-12.txt", timAcc, timMod+10.msecs);
		fs.writeText(   "filestest/dst/test5-22.txt", "5");
		fs.setTimeStamp("filestest/dst/test5-22.txt", timAcc, timMod+10.msecs);
		fs.mirrorFiles( "filestest/src", "filestest/dst");
		assert( "ut/filestest/src/test1-1.txt".exists);
		assert( "ut/filestest/src/test1-2.txt".exists);
		assert( "ut/filestest/src/test2-1.txt".exists);
		assert( "ut/filestest/src/test2-2.txt".exists);
		assert(!"ut/filestest/src/test3.txt".exists);
		assert( "ut/filestest/src/test4.txt".exists);
		assert( "ut/filestest/dst/test1-1.txt".exists);
		assert( "ut/filestest/dst/test1-2.txt".exists);
		assert( "ut/filestest/dst/test2-1.txt".exists);
		assert( "ut/filestest/dst/test2-2.txt".exists);
		assert(!"ut/filestest/dst/test3.txt".exists);
		assert( "ut/filestest/dst/test4.txt".exists);
		assert((cast(string)std.file.read("ut/filestest/dst/test1-1.txt")) == "1");
		assert((cast(string)std.file.read("ut/filestest/dst/test1-2.txt")) == "1");
		assert((cast(string)std.file.read("ut/filestest/dst/test2-1.txt")) == "2");
		assert((cast(string)std.file.read("ut/filestest/dst/test2-2.txt")) == "2");
		assert((cast(string)std.file.read("ut/filestest/dst/test4.txt")) == "4");
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
		string execFileName = executable.setExtension(".exe");
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
		
		foreach (dir; splitter(to!string(paths), ';'))
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
		makeDir(".");
		return .spawnProcess([searchPath(args[0])] ~ args[1..$],
		                      stdin, stdout, stderr, env, cfg, workDir);
	}
	
	/// ditto
	auto spawnProcess(string[] args, File fin, File fout, File ferr,
	                  string[string] env = null,
	                  std.process.Config cfg = std.process.Config.suppressConsole)
	{
		makeDir(".");
		return .spawnProcess([searchPath(args[0])] ~ args[1..$],
		                      fin  is File.init ? File.init : fin,
		                      fout is File.init ? File.init : fout,
		                      ferr is File.init ? File.init : ferr,
		                      env, cfg, workDir);
	}
	
	/// ditto
	auto spawnProcess(string[] args, Pipe pin, Pipe pout, Pipe perr,
	                  string[string] env = null,
	                  std.process.Config cfg = std.process.Config.suppressConsole)
	{
		makeDir(".");
		return .spawnProcess([searchPath(args[0])] ~ args[1..$],
		                     pin  is Pipe.init ? File.init : pin.readEnd,
		                     pout is Pipe.init ? File.init : pout.writeEnd,
		                     perr is Pipe.init ? File.init : perr.writeEnd,
		                     env, cfg, workDir);
	}
	
	/// ditto
	auto pipeProcess(string[] args, string[string] env = null,
	                 std.process.Config cfg = std.process.Config.suppressConsole)
	{
		makeDir(".");
		return .pipeProcess([searchPath(args[0])] ~ args[1..$],
		                     Redirect.all, env, cfg, workDir);
	}
	
	/// ditto
	auto execute(string[] args, string[string] env = null,
	             std.process.Config cfg = std.process.Config.suppressConsole)
	{
		makeDir(".");
		return .execute([searchPath(args[0])] ~ args[1..$],
		                 env, cfg, size_t.max, workDir);
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		auto pipeo = pipe();
		auto pid = fs.spawnProcess(["cmd", "/C", "echo xxx"], Pipe.init, pipeo, pipeo);
		pid.wait();
		auto xxx = pipeo.readEnd().readln;
		assert(xxx == "xxx\r\n");
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		auto pipeo = pipe();
		auto pipe = fs.pipeProcess(["cmd", "/C", "echo xxx"]);
		pipe.pid.wait();
		auto xxx = pipe.stdout().readln;
		assert(xxx == "xxx\r\n");
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		auto tout = fs.createFile("test.txt");
		auto pid = fs.spawnProcess(["cmd", "/C", "echo xxx"], File.init, tout, File.init);
		pid.wait();
		tout.close();
		auto result = fs.readText("test.txt");
		assert(result == "xxx\r\n");
	}
	
	///
	@system unittest
	{
		scope (exit)
			std.file.rmdirRecurse("ut");
		auto fs = FileSystem("ut");
		auto result = fs.execute(["cmd", "/C", "echo xxx"]);
		assert(result.output == "xxx\r\n");
	}
}
