/*******************************************************************************
 * sync モジュール
 * 
 * よく使う同期用クラスのインターフェースを利用可能。
 * $(UL
 *     $(LI Light )
 *     $(LI NamedMutex )
 * )
 * 
 * Date: July 29, 2009
 * Authors:
 *     P.Knowledge, SHOO
 * License:
 *     NYSL ( http://www.kmonos.net/nysl/ )
 * 
 */
module voile.sync;


import core.thread, core.sync.mutex, core.sync.condition;

version (Windows)
{
	private enum uint INFINITE = 0xFFFFFFFF;
	private enum uint WAIT_OBJECT_0 = 0x00000000;
	private alias void* HANDLE;
	private extern(Windows) uint WaitForSingleObject(in HANDLE, uint);
	private extern(Windows) int CloseHandle(in HANDLE);
	private extern(Windows) HANDLE CreateEventW(void*, int, int, void*);
	private extern(Windows) int SetEvent(in HANDLE);
	private extern(Windows) int ResetEvent(in HANDLE);
}

/*******************************************************************************
 * 同期イベントクラス
 * 
 * Windowsの CreateEvent や SetEvent のラッパー
 * Windows以外の環境でも動作するが、最適な実装ではないかもしれない。
 * Example:
 *------------------------------------------------------------------------------
 *SyncEvent[3] ev;
 *int data;
 *void run1()
 *{
 *	data = 1;
 *	ev[0].signal = true;
 *}
 *
 *void run2()
 *{
 *	data = 2;
 *	ev[1].signal = true;
 *}
 *
 *void run3()
 *{
 *	data = 3;
 *	ev[2].signal = true;
 *}
 *void main()
 *{
 *	ev[] = [new Light, new Light, new Light];
 *	scope t = new ThreadGroup;
 *	data = 0;
 *	t.create(&run1);
 *	ev[0].wait;
 *	assert(data == 1);
 *	data = 0;
 *	t.create(&run2);
 *	ev[1].wait;
 *	assert(data == 2);
 *	data = 0;
 *	t.create(&run3);
 *	ev[2].wait;
 *	assert(data == 3);
 *}
 *------------------------------------------------------------------------------
 */
class SyncEvent
{
	version(Windows)
	{
		private static HANDLE createEvent(bool aFirstCondition = false)
		{
			auto h = CreateEventW(null, 1, aFirstCondition ? 1 : 0, null);
			return h;
		}
		private static void closeEvent(HANDLE h)
		{
			CloseHandle(h);
		}
		private HANDLE _handle = null;
		private const bool _ownHandle;
		/***********************************************************************
		 * ハンドルを得る
		 * 
		 * ただしOS依存する処理をする場合にのみ使用すること
		 */
		HANDLE handle()
		{
			return _handle;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: h = イベントハンドル
		 */
		this(HANDLE h)
		{
			_ownHandle = false;
			_handle = h;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: firstCondition = 初期状態
		 */
		this(bool firstCondition = false)
		{
			_ownHandle = true;
			_handle = createEvent(firstCondition);
		}
		/***********************************************************************
		 * シグナル状態を返す
		 * 
		 * Returns:
		 *     trueならシグナル状態で、waitはすぐに制御を返す
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるか、時間が
		 *     過ぎるまで制御を返さない状態であることを示す。
		 */
		@property bool signaled()
		{
			return WaitForSingleObject(_handle, 0) == WAIT_OBJECT_0;
		}
		/***********************************************************************
		 * シグナル状態を設定する
		 * 
		 * Params: cond=
		 *     trueならシグナル状態にし、waitしているスレッドの制御を返す。
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるまで制御を
		 *     返さない状態にする。
		 */
		@property void signaled(bool cond)
		{
			if (cond == true && signaled == false)
			{
				SetEvent(_handle);
			}
			else if (cond == false && signaled == true)
			{
				ResetEvent(_handle);
			}
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるまで制御を
		 * 返さない。
		 */
		void wait()
		{
			WaitForSingleObject(_handle, INFINITE);
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(Duration dir)
		{
			return WaitForSingleObject(_handle, cast(uint)dir.total!"msecs")
				== WAIT_OBJECT_0;
		}
		~this()
		{
			if ( _ownHandle )
			{
				closeEvent(_handle);
				_handle = null;
			}
		}
	}
	else
	{
		private Condition _condition;
		private Mutex _mutex;
		private bool _signaled;
		/***********************************************************************
		 * ハンドルを得る
		 * 
		 * ただしOS依存する処理をする場合にのみ使用すること
		 */
		@property
		Condition handle()
		{
			return _condition;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: firstCondition = 初期状態
		 */
		this(bool firstCondition = false)
		{
			_signaled = firstCondition;
			_mutex = new Mutex;
			_condition = new Condition(_mutex);
		}
		/***********************************************************************
		 * シグナル状態を返す
		 * 
		 * Returns:
		 *     trueならシグナル状態で、waitはすぐに制御を返す
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるか、時間が
		 *     過ぎるまで制御を返さない状態であることを示す。
		 */
		@property
		bool signaled()
		{
			synchronized (_mutex)
			{
				return _signaled;
			}
		}
		/***********************************************************************
		 * シグナル状態を設定する
		 * 
		 * Params: cond=
		 *     trueならシグナル状態にし、waitしているスレッドの制御を返す。
		 *     falseなら非シグナル状態で、waitしたらシグナル状態になるまで制御を
		 *     返さない状態にする。
		 */
		@property
		void signaled(bool cond)
		{
			synchronized (_mutex)
			{
				_signaled = cond;
				_condition.notifyAll;
			}
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるまで制御を
		 * 返さない。
		 */
		void wait()
		{
			synchronized (_mutex)
			{
				while (! _signaled) _condition.wait;
			}
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(double period)
		{
			synchronized (_mutex)
			{
				while (! _signaled) _condition.wait(period);
				return _signaled;
			}
		}
	}
}

unittest
{
	int data;
	SyncEvent[3] ev;
	void run1()
	{
		data = 1;
		ev[0].signaled = true;
	}
	
	void run2()
	{
		data = 2;
		ev[1].signaled = true;
	}
	
	void run3()
	{
		data = 3;
		ev[2].signaled = true;
	}
	ev[] = [new SyncEvent, new SyncEvent, new SyncEvent];
	scope t = new ThreadGroup;
	data = 0;
	t.create(&run1);
	ev[0].wait();
	assert(data == 1);
	data = 0;
	t.create(&run2);
	ev[1].wait();
	assert(data == 2);
	data = 0;
	t.create(&run3);
	ev[2].wait();
	assert(data == 3);
}




version (Posix)
{
	version (Tango)
	{
		private import tango.stdc.posix.semaphore;
		private import tango.stdc.posix.fcntl;
		private import tango.stdc.posix.sys.stat: S_IRWXU, S_IRWXG, S_IRWXO;
		private static const s777 = S_IRWXU|S_IRWXG|S_IRWXO;
		private import tango.stdc.errno;
	}
	else
	{
		private import core.sys.posix.semaphore;
		private import core.sys.posix.fcntl;
		private import core.sys.posix.sys.stat: S_IRWXU, S_IRWXG, S_IRWXO;
		private static const s777 = S_IRWXU|S_IRWXG|S_IRWXO;
		private import core.stdc.errno;
	}
	private alias sem_t* HANDLE;
}
else version (Windows)
{
	version (Tango)
	{
		private import tango.sys.Common: CreateMutexW, ReleaseMutex;
	}
	else
	{
		private extern (Windows) HANDLE CreateMutexW(void*,int,in wchar*);
		private extern (Windows) int ReleaseMutex(in HANDLE);
	}
}
else
{
	static assert(0, "Posix or Windows only");
}

/*******************************************************************************
 * 名前付きミューテックス
 * 
 * プロセス間で共有される名前付きミューテックスの作成を行う。
 */
class NamedMutex: Object.Monitor
{
private:
	static struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy m_Proxy;
	version(D_Version2)
	{
	}
	else
	{
		alias char[] string;
	}
	const HANDLE _handle;
	const string m_Name;
	version (Posix) const string m_SavedName;
public:
	/***************************************************************************
	 * コンストラクタ
	 * 
	 * Params:
	 *     aName=名前付きミューテックスの名前を指定する。名前は128文字以内。
	 */
	this(string aName)
	{
		assert(aName.length < 750);
		m_Proxy.link = this;
		this.__monitor = &m_Proxy;
		m_Name = aName;
		version (Posix)
		{
			alias char char_t;
		}
		else version (Windows)
		{
			alias wchar char_t;
		}
		char_t[1024*4] buf;
		static char_t[] encodeStr(string str, char_t[] aBuf)
		{
			auto dBuf = aBuf;
			dBuf[0..(cast(char_t[])"/voile::NamedMutex[").length] = cast(char_t[])"/voile::NamedMutex[";
			size_t j=(cast(char_t[])"/voile::NamedMutex[").length;
			foreach (char c; str)
			{
				switch (c)
				{
				case '%':
					dBuf[j++] = '%';
					dBuf[j++] = '%';
					break;
				case '\\':
					dBuf[j++] = '%';
					dBuf[j++] = '5';
					dBuf[j++] = 'c';
					break;
				case '/':
					dBuf[j++] = '%';
					dBuf[j++] = '2';
					dBuf[j++] = 'f';
					break;
				default:
					dBuf[j++] = c;
					break;
				}
			}
			if (j >= dBuf.length - 1)
				dBuf.length = dBuf.length + 2;
			dBuf[j++] = ']';
			dBuf[j++] = '\0';
			return dBuf[0..j];
		}
		version (Posix)
		{
			auto tmpname = m_SavedName = encodeStr(name, buf);
		}
		else
		{
			auto tmpname = encodeStr(name, buf);
		}
		if (tmpname.length >= 250)
		{
			throw new Exception("名前が長すぎます");
		}
		
		version (Posix)
		{
			_handle = sem_open(tmpname.ptr, O_CREAT, s777, 1);
		}
		else version (Windows)
		{
			_handle = CreateMutexW(null, 0, tmpname.ptr);
		}
	}
	
	/***************************************************************************
	 * 名前を返す。
	 */
	@property const string name()
	{
		return m_Name;
	}
	
	/***************************************************************************
	 * デストラクタ
	 * 
	 * 名前付きミューテックスの削除を行う
	 */
	~this()
	{
		this.__monitor = null;
		version (Posix)
		{
			sem_close(_handle);
			sem_unlink(m_SavedName.ptr);
		}
		else version (Windows)
		{
			CloseHandle(_handle);
		}
	}
	/***************************************************************************
	 * ロックする
	 * 
	 * ロックが成功するまで制御は返らない
	 */
	void lock()
	{
		version (Posix)
		{
			sem_wait(_handle);
		}
		else version (Windows)
		{
			WaitForSingleObject(_handle, 0xffffffff);
		}
	}
	/***************************************************************************
	 * ロックの試行
	 * 
	 * 即座に制御が返る。
	 * trueが帰った場合ロックが成功している。
	 * falseなら別のMutexにロックされているため、ロックされなかった。
	 */
	bool tryLock()
	{
		version (Posix)
		{
			return sem_trywait(_handle) == 0;
		}
		else version (Windows)
		{
			return WaitForSingleObject(_handle, 0) == 0;
		}
	}
	/***************************************************************************
	 * ロック解除
	 */
	void unlock()
	{
		version (Posix)
		{
			sem_post(_handle);
		}
		else version (Windows)
		{
			ReleaseMutex(_handle);
		}
	}
}



/*******************************************************************************
 * 管理された共有資源
 * 
 * 初期状態は非共有資源。
 */
class ManagedShared(T): Object.Monitor
{
private:
	import core.sync.mutex, core.atomic;
	import std.exception;
	static struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy _proxy;
	Mutex        _mutex;
	size_t       _locked;
	T            _data;
	void _initData()
	{
		_proxy.link = this;
		this.__monitor = &_proxy;
		_mutex = new Mutex();
		lock();
	}
public:
	
	/***************************************************************************
	 * 
	 */
	this() pure
	{
		// これはひどい
		(cast(void delegate() pure)&_initData)();
	}
	
	
	/***************************************************************************
	 * ロックされたデータを得る
	 * 
	 * RAIIで自動的に
	 */
	auto locked() @property
	{
		lock();
		static struct LockedData
		{
		private:
			ManagedShared!T _data;
			ref T _dataRef() @property { return _data._data; }
			this(ManagedShared!T dat){_data = dat;}
			import std.typecons;
		public:
			~this()
			{
				_data.unlock();
			}
			mixin Proxy!_dataRef;
		}
		return LockedData(this);
	}
	/// ditto
	auto locked() shared @property
	{
		return (cast()this).locked();
	}
	
	
	/***************************************************************************
	 * ロックを試行する。
	 * 
	 * Returns:
	 *     すでにロックしているならtrue
	 *     ロックされていなければロックしてtrue
	 *     別のスレッドにロックされていてロックできなければfalse
	 */
	bool tryLock()
	{
		auto tmp = _mutex.tryLock();
		// ロックされていなければ _locked を操作することは許されない
		if (tmp)
			_locked++;
		return tmp;
	}
	/// ditto
	bool tryLock() shared
	{
		return (cast()this).tryLock();
	}
	
	
	/***************************************************************************
	 * ロックする。
	 */
	void lock()
	{
		_mutex.lock();
		_locked++;
	}
	/// ditto
	void lock() shared
	{
		(cast()this).lock();
	}
	
	
	/***************************************************************************
	 * ロック解除する。
	 */
	void unlock()
	{
		_locked--;
		_mutex.unlock();
	}
	/// ditto
	void unlock() shared
	{
		(cast()this).unlock();
	}
	
	
	/***************************************************************************
	 * 非共有資源としてアクセスする
	 */
	ref T asUnshared() @property
	{
		enforce(_locked != 0);
		return *cast(T*)&_data;
	}
	/// ditto
	ref T asUnshared() shared @property
	{
		enforce(_locked != 0);
		return *cast(T*)&_data;
	}
	
	
	/***************************************************************************
	 * 共有資源としてアクセスする
	 */
	ref shared(T) asShared() @property
	{
		return *cast(shared(T)*)&_data;
	}
	/// ditto
	ref shared(T) asShared() shared @property
	{
		return *cast(shared(T)*)&_data;
	}
}


/*******************************************************************************
 * 
 */
ManagedShared!T managedShared(T, Args...)(Args args)
{
	auto s = new ManagedShared!T;
	static if (Args.length == 0 && is(typeof(s.asUnshared.__ctor())))
	{
		s.asUnshared.__ctor();
	}
	else static if (is(typeof(s.asUnshared.__ctor(args))))
	{
		s.asUnshared.__ctor(args);
	}
	return s;
}

unittest
{
	auto s = managedShared!int();
	s.asUnshared += 50;
	s.asShared   += 100;
	s.unlock();
	try
	{
		s.asUnshared += 200;
		assert(0);
	}
	catch (Exception e) { }
	s.lock();
	s.asUnshared += 200;
	assert(s.asShared == 350);
	s.unlock();
	
	{
		auto ld = s.locked;
		assert(s._locked);
		ld += 1;
	}
	assert(!s._locked);
	assert(s.asShared == 351);
	
	synchronized (s)
	{
		assert(s._locked);
		{
			auto ld = s.locked;
			assert(s._locked);
			ld += 2;
		}
		import std.stdio;
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 353);
}


unittest
{
	auto s = new shared ManagedShared!int();
	s.asUnshared += 50;
	s.asShared   += 100;
	s.unlock();
	try
	{
		s.asUnshared += 200;
		assert(0);
	}
	catch (Exception e) { }
	s.lock();
	s.asUnshared += 200;
	assert(s.asShared == 350);
	s.unlock();
	
	{
		auto ld = s.locked;
		assert(s._locked);
		ld += 1;
	}
	assert(!s._locked);
	assert(s.asShared == 351);
	
	synchronized (s)
	{
		assert(s._locked);
		{
			auto ld = s.locked;
			assert(s._locked);
			ld += 2;
		}
		import std.stdio;
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 353);
}

private template AssumedUnsharedType(T)
{
	import std.traits;
	static if (is(T U == shared(U)))
	{
		alias AssumedUnsharedType!(U) AssumedUnsharedType;
	}
	else static if (is(T U == const(shared(U))))
	{
		alias const(AssumedUnsharedType!(U)) AssumedUnsharedType;
	}
	else static if (isPointer!T)
	{
		alias AssumedUnsharedType!(pointerTarget!T)* AssumedUnsharedType;
	}
	else static if (isDynamicArray!T)
	{
		alias AssumedUnsharedType!(ForeachType!T)[] AssumedUnsharedType;
	}
	else static if (isStaticArray!T)
	{
		alias AssumedUnsharedType!(ForeachType!T)[T.length] AssumedUnsharedType;
	}
	else static if (isAssociativeArray!T)
	{
		alias AssumedUnsharedType!(ValueType!T)[AssumedUnsharedType!(KeyType!T)] AssumedUnsharedType;
	}
	else
	{
		alias T AssumedUnsharedType;
	}
}

auto ref assumeUnshared(T)(ref T x) @property
{
	return *cast(AssumedUnsharedType!(T)*)&x;
}
