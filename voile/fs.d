module voile.fs;

import std.file, std.path, std.exception, std.stdio;
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
	 *     target = 変換したい相対パス(何も指定しないとworkDirの絶対パスが返る))
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
	 *     target = パス
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
}
