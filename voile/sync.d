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


import core.thread, core.sync.mutex, core.sync.condition, core.sync.event, core.atomic;
version (Windows)
{
	import core.sys.windows.windows;
}
import std.traits, std.parallelism;

public import voile.misc: assumeUnshared, assumeShared;

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
		private static HANDLE createEvent(bool aFirstCondition = false) nothrow @nogc
		{
			auto h = CreateEventW(null, 1, aFirstCondition ? 1 : 0, null);
			return h;
		}
		private static void closeEvent(HANDLE h) nothrow @nogc
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
		this(HANDLE h) pure nothrow @nogc
		{
			_ownHandle = false;
			_handle = h;
		}
		/***********************************************************************
		 * コンストラクタ
		 * 
		 * Params: firstCondition = 初期状態
		 */
		this(bool firstCondition = false) nothrow @nogc
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
		@property bool signaled() nothrow @nogc
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
		@property void signaled(bool cond) nothrow @nogc
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
		void wait() nothrow @nogc const
		{
			WaitForSingleObject(cast(HANDLE)_handle, INFINITE);
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(Duration dir) nothrow @nogc const
		{
			return WaitForSingleObject(cast(HANDLE)_handle, cast(uint)dir.total!"msecs")
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
		void wait() const
		{
			synchronized (_mutex)
			{
				while (! _signaled)
					(cast()_condition).wait();
			}
		}
		/***********************************************************************
		 * シグナル状態になるまで待つ
		 * 
		 * conditionがtrueならシグナル状態であり、すぐに制御が返る。
		 * conditionがfalseなら非シグナル状態で、シグナル状態になるか、時間が
		 * 過ぎるまで制御を返さない。
		 */
		bool wait(Duration dur)
		{
			synchronized (_mutex)
			{
				while (! _signaled)
					_condition.wait(dur);
				return _signaled;
			}
		}
	}
}

@system unittest
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


version (Windows) HANDLE handle(ref Event e) @system @property
{
	return *cast(HANDLE*)&e;
}
version (Windows) @system unittest
{
	import core.sys.windows.windows;
	Event e;
	e.initialize(true, true);
	auto res = ResetEvent(e.handle);
	assert(res != FALSE);
	assert(GetLastError() == 0);
	e.terminate();
}

version (Posix)
{
	private import core.sys.posix.semaphore;
	private import core.sys.posix.fcntl;
	private import core.sys.posix.sys.stat: S_IRWXU, S_IRWXG, S_IRWXO;
	private static const s777 = S_IRWXU|S_IRWXG|S_IRWXO;
	private import core.stdc.errno;
	private alias HANDLE = sem_t*;
}
else version (Windows)
{
	private extern (Windows) HANDLE CreateMutexW(void*,int,in wchar*) nothrow @nogc;
	private extern (Windows) int ReleaseMutex(in HANDLE) nothrow @nogc;
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
	HANDLE _handle;
	string m_Name;
	version (Posix) string m_SavedName;
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
			alias char_t = char;
		}
		else version (Windows)
		{
			alias char_t = wchar;
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
			if (j + 1 >= dBuf.length)
				dBuf.length = dBuf.length + 2;
			dBuf[j++] = ']';
			dBuf[j++] = '\0';
			return dBuf[0..j];
		}
		version (Posix)
		{
			auto tmpname = m_SavedName = cast(string)encodeStr(name, buf);
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
	string name() pure nothrow @safe @nogc const @property
	{
		return m_Name;
	}
	
	/***************************************************************************
	 * デストラクタ
	 * 
	 * 名前付きミューテックスの削除を行う
	 */
	~this() nothrow @nogc
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
	void lock() nothrow @nogc
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
	bool tryLock() nothrow @nogc
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
	void unlock() nothrow @nogc
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




private template QueuedSemImpl()
{
private:
	import core.sync.mutex, core.sync.semaphore;
	Semaphore[]  _sems;
	Mutex        _mutex;
	size_t       _count;
	
	void _lockImpl()
	{
		import std.algorithm, std.array;
		Semaphore s;
		synchronized (_mutex)
		{
			if (_count == 0)
			{
				s = new Semaphore;
				_sems ~= s;
			}
			else
			{
				_count--;
				return;
			}
		}
		s.wait();
	}
	
	bool _tryLockImpl()
	{
		synchronized (_mutex)
		{
			if (_count == 0)
				return false;
			_count--;
		}
		return true;
	}
	
	void _unlockImpl()
	{
		synchronized (_mutex)
		{
			if (_sems.length == 0)
			{
				_count++;
			}
			else
			{
				_sems[0].notify();
				_sems = _sems[1..$];
			}
		}
	}
	
	void _initialize(size_t cnt)
	{
		_count = cnt;
		_mutex = new Mutex;
	}
}

/*******************************************************************************
 * 
 */
class QueuedMutex: Object.Monitor
{
private:
	struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy _proxy;
	mixin QueuedSemImpl;
public:
	///
	this()
	{
		_initialize(1);
		_proxy.link = this;
		this.__monitor = cast(void*)&_proxy;
	}
	///
	this() shared
	{
		(cast()this)._initialize(1);
		_proxy.link = this;
		this.__monitor = cast(void*)&_proxy;
	}
	
	
	///
	void lock() @trusted
	{
		_lockImpl();
	}
	
	///
	void lock() @trusted shared
	{
		(cast()this)._lockImpl();
	}
	
	///
	bool tryLock() @trusted
	{
		return _tryLockImpl();
	}
	
	///
	bool tryLock() @trusted shared
	{
		return (cast()this)._tryLockImpl();
	}
	
	///
	void unlock() @trusted
	{
		_unlockImpl();
	}
	
	///
	void unlock() @trusted shared
	{
		(cast()this)._unlockImpl();
	}
	
}



/*******************************************************************************
 * 
 */
class QueuedSemaphore
{
private:
	mixin QueuedSemImpl;
public:
	///
	this(size_t count = 0)
	{
		_initialize(count);
	}
	///
	this(size_t count = 0) shared
	{
		(cast()this)._initialize(count);
	}
	
	///
	void wait() @trusted
	{
		_lockImpl();
	}
	
	///
	void wait() @trusted shared
	{
		(cast()this)._lockImpl();
	}
	
	///
	bool tryWait() @trusted
	{
		return _tryLockImpl();
	}
	
	///
	bool tryWait() @trusted shared
	{
		return (cast()this)._tryLockImpl();
	}
	
	///
	void notify() @trusted
	{
		_unlockImpl();
	}
	
	///
	void notify() @trusted shared
	{
		(cast()this)._unlockImpl();
	}
	
}


/***************************************************************************
 * タスクの例外処理
 */
private void _execTaskOnFailed(Fut)(Fut future, Exception e)
{
	import std.algorithm: move;
	Fut.FailedHandler call;
	synchronized (future)
	{
		call = future._onFailed.move();
		future._resultException = e;
		future._type = Fut.FinishedType.failed;
	}
	call(e);
	throw e;
}

/***************************************************************************
 * タスクの異常処理
 */
private void _execTaskOnFatal(Fut)(Fut future, Throwable e)
{
	import std.algorithm: move;
	Fut.FatalHandler call;
	synchronized (future)
	{
		call = future._onFatal.move();
		future._resultFatal = e;
		future._type = Fut.FinishedType.fatal;
	}
	call(e);
	throw e;
}


/***************************************************************************
 * タスクを生成する
 */
private void _makeTask(alias func, Fut, Args...)(Fut future, Args args)
{
	import std.algorithm: move;
	alias Ret = Fut.ResultType;
	synchronized (future)
	{
		future._type = Fut.FinishedType.none;
		future._resultException = null;
	}
	auto dg = ()
	{
		future._evStart.signaled = true;
		try
		{
			static if (is(Ret == void))
			{
				Fut.FinishedHandler call;
				func(args);
				synchronized (future)
				{
					call = future._onFinished.move();
					future._type = Fut.FinishedType.done;
				}
				call();
				return;
			}
			else
			{
				Fut.FinishedHandler call;
				future._resultRaw() = func(args);
				synchronized (future)
				{
					call = future._onFinished.move();
					future._type = Fut.FinishedType.done;
				}
				call(future._resultRaw);
				return future._resultRaw;
			}
		}
		catch (Exception e)
		{
			_execTaskOnFailed(future, e);
		}
		catch (Throwable e)
		{
			_execTaskOnFatal(future, e);
		}
		assert(0);
	};
	future._task = task(dg);
}


private auto _dgRun(F, Args...)(F dg, Args args)
{
	return dg(args);
}


/*******************************************************************************
 * 
 */
final class Future(Ret)
{
	import voile.handler;
	alias TaskFunc = Ret delegate();
	alias TaskType = typeof(task(TaskFunc.init));
	alias ResultType = Ret;
	static if (is(Ret == void))
	{
		alias CallbackType = void delegate();
	}
	else
	{
		alias CallbackType = void delegate(ref ResultType res);
	}
	alias CallbackFailedType = void delegate(Exception) nothrow;
	alias CallbackFatalType  = void delegate(Throwable) nothrow;
	alias FinishedHandler    = Handler!CallbackType;
	alias FailedHandler      = Handler!CallbackFailedType;
	alias FatalHandler       = Handler!CallbackFatalType;
private:
	FinishedHandler _onFinished;
	FailedHandler   _onFailed;
	FatalHandler    _onFatal;
	TaskType        _task;
	TaskPool        _taskPool;
	SyncEvent       _evStart;
	
	enum FinishedType
	{
		none, done, failed, fatal
	}
	
	FinishedType _type;
	union
	{
		Exception _resultException;
		Throwable _resultFatal;
	}
	
	static if (is(Ret == void))
	{
		void _resultRaw() inout @property
		{
			// 何もしない
		}
	}
	else
	{
		ref inout(ResultType) _resultRaw() inout @property
		{
			return *cast(inout(ResultType)*)&(cast(Future)this)._task.fixRef((cast(Future)this)._task.returnVal);
		}
	}
	
public:
	/***************************************************************************
	 * コンストラクタ
	 */
	this()
	{
		_evStart = new SyncEvent(false);
	}
	/// ditto
	this(SyncEvent evStart)
	{
		_evStart = evStart;
		if (evStart is SyncEvent.init)
		{
			_type = FinishedType.done;
		}
	}
	/// ditto
	this(SyncEvent evStart, TaskPool pool)
	{
		this(evStart);
		_taskPool = pool;
	}
	/// ditto
	static if (!is(Ret == void))
	{
		this(ResultType val, SyncEvent evStart = null)
		{
			import std.algorithm: move;
			static assert(isPointer!TaskType);
			// Taskのインスタンスを無理やり生成することでreturnValのスペースを確保する
			_task = new PointerTarget!TaskType;
			static if (is(typeof(_task.returnVal) == ResultType*))
				_task.returnVal = new ResultType;
			_resultRaw() = val.move();
			_type = FinishedType.done;
			if (evStart !is null)
				evStart.signaled = true;
		}
	}
	
	/***************************************************************************
	 * 終了したら呼ばれる
	 */
	auto perform(alias func, Args...)(TaskPool pool, Args args)
		if (is(typeof(func(args)) == ResultType))
	{
		_makeTask!func(this, args);
		_taskPool = pool;
		pool.put(_task);
		return this;
	}
	/// ditto
	auto perform(alias func, Args...)(Args args)
		if (is(typeof(func(args)) == ResultType))
	{
		_makeTask!func(this, args);
		if (_taskPool)
		{
			_taskPool.put(_task);
		}
		else
		{
			_task.executeInNewThread();
		}
		return this;
	}
	/// ditto
	auto perform(F, Args...)(TaskPool pool, F dg, Args args)
		if (is(typeof(dg(args)) == ResultType))
	{
		_makeTask!_dgRun(this, dg, args);
		_taskPool = pool;
		pool.put(_task);
		return this;
	}
	/// ditto
	auto perform(F, Args...)(F dg, Args args)
		if (is(typeof(dg(args)) == ResultType))
	{
		_makeTask!_dgRun(this, dg, args);
		if (_taskPool)
		{
			_taskPool.put(_task);
		}
		else
		{
			_task.executeInNewThread();
		}
		return this;
	}
	
	private void _addListenerFailedWithNewFeature(Ret2)(CallbackFailedType callbackFailed, Future!Ret2 future)
	{
		addListenerFailed(cast(CallbackFailedType)(Exception e)
		{
			scope (exit)
				future._evStart.signaled = true;
			synchronized (future)
			{
				future._resultException = e;
				future._type = Future!Ret2.FinishedType.failed;
			}
			if (callbackFailed)
				callbackFailed(e);
		});
	}
	private void _addListenerFatalWithNewFeature(Ret2)(CallbackFatalType callbackFatal, Future!Ret2 future)
	{
		addListenerFatal(cast(CallbackFatalType)(Throwable e){
			scope (exit)
				future._evStart.signaled = true;
			synchronized (future)
			{
				future._resultFatal = e;
				future._type = Future!Ret2.FinishedType.fatal;
			}
			if (callbackFatal)
				callbackFatal(e);
		});
	}
	
	/***************************************************************************
	 * チェーン
	 */
	auto then(Ret2)(TaskPool pool,
		Ret2 delegate(ResultType) callbackFinished,
		void delegate(Exception e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (!is(Ret == void) && is(typeof(callbackFinished(_resultRaw))))
	{
		auto ret = new Future!Ret2;
		addListenerFinished((ref ResultType result) { ret.perform(pool, callbackFinished, result); });
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(Ret2)(
		Ret2 delegate(ResultType) callbackFinished,
		void delegate(Exception e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (!is(Ret == void) && is(typeof(callbackFinished(_resultRaw))))
	{
		auto ret = new Future!Ret2;
		addListenerFinished((ref ResultType result){ ret.perform(callbackFinished, result); });
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(TaskPool pool,
		void delegate(Ex e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (!is(Ret == void) && is(typeof(func(_resultRaw))) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func(_resultRaw)));
		addListenerFinished((ref ResultType result) { ret.perform!func(pool, result); });
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(
		void delegate(Ex e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (!is(Ret == void) && is(typeof(func(_resultRaw))) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func(_resultRaw)));
		addListenerFinished((ref ResultType result) { ret.perform!func(result); });
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(Ret2)(TaskPool pool,
		Ret2 delegate() callbackFinished,
		void delegate(Exception e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (is(Ret == void) && is(typeof(callbackFinished())))
	{
		auto ret = new Future!Ret2;
		addListenerFinished(() { ret.perform(pool, callbackFinished); });
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(Ret2)(
		Ret2 delegate() callbackFinished,
		void delegate(Exception e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (is(Ret == void) && is(typeof(callbackFinished())))
	{
		auto ret = new Future!Ret2;
		addListenerFinished((){ ret.perform(callbackFinished); });
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(TaskPool pool,
		void delegate(Ex e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (is(Ret == void) && is(typeof(func())) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func()));
		addListenerFinished( () { ret.perform!func(pool); });
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(
		void delegate(Ex e) nothrow callbackFailed = null,
		void delegate(Throwable e) nothrow callbackFatal = null)
		if (is(Ret == void) && is(typeof(func())) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func()));
		addListenerFinished( () { ret.perform!func(); } );
		_addListenerFailedWithNewFeature(callbackFailed, ret);
		_addListenerFatalWithNewFeature(callbackFatal, ret);
		return ret;
	}
	/***************************************************************************
	 * 終了したら呼ばれるコールバックをハンドラに登録
	 * 
	 * 指定されたコールバックは並列処理が正常終了したときにのみ呼び出される。
	 * 並列処理がまだ終了していない場合には並列処理を行っていたスレッドでコールバックが呼び出されるが、
	 * すでに並列処理が終了していた場合には現在のスレッドで即座にコールバックが呼び出される。
	 * すでに終了していて、かつコールバック内で例外が発生した場合には、Failed, Fatalのハンドラが呼び出され、
	 * Futureの状態も各々の状態へと変化する。
	 * 
	 * Params:
	 *     dg = 設定するコールバックを指定する。nullを指定したらハンドラに登録されたすべてのコールバックをクリアする。
	 * Returns:
	 *     登録したハンドラのIDを返す。登録されなかった場合はFinishedHandler.HandlerProcId.initが返る
	 */
	FinishedHandler.HandlerProcId addListenerFinished(CallbackType dg)
	{
		import std.algorithm: move;
		synchronized (this)
		{
			if (dg is null)
			{
				_onFinished.clear();
				return FinishedHandler.HandlerProcId.init;
			}
			else
			{
				if (_type == FinishedType.none)
				{
					return _onFinished.connect(dg);
				}
				else if (_type != FinishedType.done)
				{
					return FinishedHandler.HandlerProcId.init;
				}
				else
				{
					// 何もしない=関数の最後でdgの呼び出しを行う
				}
			}
		}
		try
		{
			static if (is(Ret == void))
			{
				dg();
			}
			else
			{
				dg(_resultRaw);
			}
		}
		catch (Exception e)
		{
			FailedHandler call;
			synchronized (this)
			{
				call = _onFailed.move();
				_type = FinishedType.failed;
			}
			call(e);
		}
		catch (Throwable e)
		{
			FatalHandler call;
			synchronized (this)
			{
				call = _onFatal.move();
				_type = FinishedType.fatal;
			}
			call(e);
		}
		return FinishedHandler.HandlerProcId.init;
	}
	
	/***************************************************************************
	 * 例外が発生したら呼ばれる
	 * 
	 * Params:
	 *     dg = 設定するコールバックを指定する。nullを指定したらすべてのコールバックをクリアする。
	 * Returns:
	 *     登録したハンドラのIDを返す。登録されなかった場合はFailedHandler.HandlerProcId.initが返る
	 */
	FailedHandler.HandlerProcId addListenerFailed(CallbackFailedType dg)
	{
		synchronized (this)
		{
			if (dg is null)
			{
				_onFailed.clear();
				return FailedHandler.HandlerProcId.init;
			}
			else
			{
				if (_type == FinishedType.none)
				{
					return _onFailed.connect(dg);
				}
				else if (_type != FinishedType.failed)
				{
					return FailedHandler.HandlerProcId.init;
				}
				else
				{
					// 何もしない=関数の最後でdgの呼び出しを行う
				}
			}
		}
		dg(_resultException);
		return FailedHandler.HandlerProcId.init;
	}
	
	
	/***************************************************************************
	 * 致命的エラーが発生したら呼ばれる
	 * 
	 * Params:
	 *     dg = 設定するコールバックを指定する。nullを指定したらすべてのコールバックをクリアする。
	 * Returns:
	 *     登録したハンドラのIDを返す。登録されなかった場合はFatalHandler.HandlerProcId.initが返る
	 */
	FatalHandler.HandlerProcId addListenerFatal(CallbackFatalType dg)
	{
		synchronized (this)
		{
			if (dg is null)
			{
				_onFatal.clear();
				return FatalHandler.HandlerProcId.init;
			}
			else
			{
				if (_type == FinishedType.none)
				{
					return _onFatal.connect(dg);
				}
				else if (_type != FinishedType.fatal)
				{
					return FatalHandler.HandlerProcId.init;
				}
				else
				{
					/* 何もしない=関数の最後でdgの呼び出しを行う */
				}
			}
		}
		dg(_resultFatal);
		return FatalHandler.HandlerProcId.init;
	}
	
	/***************************************************************************
	 * 登録していたハンドラを削除する
	 */
	void removeListenerFinished(FinishedHandler.HandlerProcId id)
	{
		synchronized (this)
		{
			_onFinished.disconnect(id);
		}
	}
	/// ditto
	void removeListenerFailed(FailedHandler.HandlerProcId id)
	{
		synchronized (this)
		{
			_onFailed.disconnect(id);
		}
	}
	/// ditto
	void removeListenerFatal(FatalHandler.HandlerProcId id)
	{
		synchronized (this)
		{
			_onFatal.disconnect(id);
		}
	}
	
	/***************************************************************************
	 * 終了しているか(例外発生含む)
	 */
	bool done() const
	{
		return !_evStart || (_type != FinishedType.none);
	}
	
	/***************************************************************************
	 * 終了するまで待機する
	 */
	void join(bool rethrow = false) const
	{
		if (!_evStart)
			return;
		_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			(cast(TaskType)_task).yieldForce();
			break;
		case FinishedType.done:
			break;
		case FinishedType.failed:
			if (rethrow)
				throw _resultException;
			break;
		case FinishedType.fatal:
			if (rethrow)
				throw _resultFatal;
			break;
		}
	}
	
	
	/***************************************************************************
	 * 結果を受け取る
	 */
	ref auto yieldForce() inout
	{
		if (!_evStart)
			return _resultRaw();
		if (_type == FinishedType.none)
			_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			(cast(TaskType)_task).yieldForce();
			return _resultRaw();
		case FinishedType.done:
			return _resultRaw();
		case FinishedType.failed:
			throw _resultException;
		case FinishedType.fatal:
			throw _resultFatal;
		}
	}
	
	/// ditto
	ref auto workForce() inout
	{
		if (!_evStart)
			return _resultRaw();
		if (_type == FinishedType.none)
			_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			(cast(TaskType)_task).workForce();
			return _resultRaw();
		case FinishedType.done:
			return _resultRaw();
		case FinishedType.failed:
			throw _resultException;
		case FinishedType.fatal:
			throw _resultFatal;
		}
	}
	
	/// ditto
	ref auto spinForce() inout
	{
		if (!_evStart)
			return _resultRaw();
		if (_type == FinishedType.none)
			_evStart.wait();
		final switch (_type)
		{
		case FinishedType.none:
			(cast(TaskType)_task).spinForce();
			return _resultRaw();
		case FinishedType.done:
			return _resultRaw();
		case FinishedType.failed:
			throw _resultException;
		case FinishedType.fatal:
			throw _resultFatal;
		}
	}
	
	static if (!is(Ret == void))
	{
		/// ditto
		ref inout(ResultType) result() inout @property
		{
			import std.exception;
			enforce((cast(Future)this)._type == FinishedType.done);
			return _resultRaw();
		}
	}
	
}

/// ditto
@system unittest
{
	auto future = new Future!int;
	future.perform(delegate (int a) => a + 10, 10);
	assert(future.yieldForce() == 20);
	future.perform(taskPool, delegate (int a) => a + 20, 10);
	assert(future.yieldForce() == 30);
	static int foo(int a) { return a + 30; }
	future.perform!foo(10);
	assert(future.yieldForce() == 40);
	future.perform!foo(taskPool, 10);
	assert(future.yieldForce() == 40);
	
	auto future2 = future.perform(delegate (int a) => a + 10, 10)
		.then((int a) => cast(ulong)(a + 20))
		.then(a => a + 20)
		.then!((ulong a) => a + 60)()
		.then(taskPool, a => cast(int)(a + 20))
		.then!((ref int a) => a + 60)(taskPool);
	auto future3 = future2
		.then((int a){ assert(a == 200); })
		.then(taskPool, (){  })
		.then((){  })
		.then!((){  })
		.then!((){  })(taskPool);
	assert(future2.yieldForce() == 200);
	future3.join();
	
}

/// ditto
@system unittest
{
	Exception lastEx;
	auto feature = async({
		throw new Exception("Ex1");
	}).then({
		assert(0);
	}, (Exception e){
		lastEx = e;
	});
	try
	{
		feature.join(true);
	}
	catch (Exception e)
	{
		assert(lastEx.msg == "Ex1");
		assert(lastEx is e);
	}
}

/// ditto
@system unittest
{
	import std.exception;
	Exception e1, e2;
	auto future1 = async({
		throw new Exception("Ex1");
	});
	auto future2 = future1.then({
		assert(0);
	}, (Exception e)
	{
		// future1の例外処理
		e1 = e;
	});
	
	// future1でEx1が投げられている
	e2 = future1.join(true).collectException();
	assert(e2.msg == "Ex1");
	// future2もEx1が投げられたことになっている
	e2 = future2.join(true).collectException();
	assert(e2.msg == "Ex1");
	assert(e1 is e2);
}

/// ditto
@system unittest
{
	import std.exception;
	Exception e1, e2;
	auto future1 = async(
	{
		// future1の処理
	});
	auto future2 = future1.then(
	{
		// feature1の後続処理
		throw new Exception("Ex1");
	}, (Exception e)
	{
		// future1の例外処理
		e1 = e;
	});
	auto future3 = future2.then(
	{
		// feature2の後続処理
		throw new Exception("Ex2");
	}, (Exception e)
	{
		// future2の例外処理
		e2 = e;
	});
	
	// future1では例外が投げられない
	auto e3 = future1.join(true).collectException();
	assert(e1 is null);
	assert(e3 is null);
	// future2ではEx1例外が投げられる
	auto e4 = future2.join(true).collectException();
	assert(e2 !is null);
	assert(e2 is e4);
	assert(e2.msg == "Ex1");
	// (Ex2は投げられない)
}

/*******************************************************************************
 * 非同期処理の開始
 */
auto async()
{
	auto ret = new Future!void(SyncEvent.init);
	ret._type = Future!void.FinishedType.done;
	return ret;
}
@system unittest
{
	auto future = async();
	future.yieldForce();
	future.workForce();
	future.spinForce();
	future.join();
}
@system unittest
{
	auto future = new Future!int(10, SyncEvent.init);
	assert(future.result == 10);
	future.join();
	assert(future.yieldForce() == 10);
	assert(future.workForce() == 10);
	assert(future.spinForce() == 10);
}

/// ditto
auto async(F, Args...)(TaskPool pool, F dg, Args args)
	if (isCallable!F)
{
	auto ret = new Future!(ReturnType!F);
	_makeTask!_dgRun(ret, dg, args);
	ret._taskPool = pool;
	pool.put(ret._task);
	return ret;
}
@system unittest
{
	auto future = async(taskPool, delegate (int a) => a + 10, 10);
	assert(future.yieldForce() == 20);
}

/// ditto
auto async(F, Args...)(F dg, Args args)
	if (isCallable!F)
{
	auto ret = new Future!(ReturnType!F);
	_makeTask!_dgRun(ret, dg, args);
	ret._task.executeInNewThread();
	return ret;
}
@system unittest
{
	auto future = async(delegate (int a) => a + 20, 10);
	assert(future.yieldForce() == 30);
}
/// ditto
auto async(alias func, Args...)(TaskPool pool, Args args)
	if (is(typeof(func(args))))
{
	auto ret = new Future!(typeof(func(args)));
	_makeTask!func(ret, args);
	pool.put(ret._task);
	ret._taskPool = pool;
	return ret;
}
@system unittest
{
	auto future = async!(a => a + 30)(taskPool, 10);
	assert(future.yieldForce() == 40);
}
/// ditto
auto async(alias func, Args...)(Args args)
	if (!is(Args[0] == TaskPool) && is(typeof(func(args))))
{
	auto ret = new Future!(typeof(func(args)));
	_makeTask!func(ret, args);
	ret._task.executeInNewThread();
	return ret;
}
@system unittest
{
	auto future = async!(a => a + 40)(10);
	assert(future.yieldForce() == 50);
}



/*******************************************************************************
 * 管理された共有資源
 * 
 * 
 */
class ManagedShared(T): Object.Monitor
{
private:
	import std.exception;
	static struct MonitorProxy
	{
		Object.Monitor link;
	}
	MonitorProxy _proxy;
	Mutex        _mutex;
	size_t       _locked;
	T            _data;
	void _initData(bool initLocked)
	{
		_proxy.link = this;
		this.__monitor = &_proxy;
		_mutex = new Mutex();
		if (initLocked)
			lock();
	}
public:
	
	/***************************************************************************
	 * コンストラクタ
	 * 
	 * sharedのコンストラクタを呼んだ場合の初期状態は共有資源(unlockされた状態)
	 * 非sharedのコンストラクタを呼んだ場合の初期状態は非共有資源(lockされた状態)
	 */
	this() pure @trusted
	{
		// これはひどい
		(cast(void delegate(bool) pure)&_initData)(true);
	}
	
	/// ditto
	this() pure @trusted shared
	{
		(cast(void delegate(bool) pure)(&(cast()this)._initData))(false);
	}
	
	
	/***************************************************************************
	 * 
	 */
	inout(Mutex) mutex() pure nothrow @nogc inout @property
	{
		return _mutex;
	}
	
	
	/***************************************************************************
	 * 
	 */
	shared(inout(Mutex)) mutex() pure nothrow @nogc shared inout @property
	{
		return _mutex;
	}
	
	
	/***************************************************************************
	 * ロックされたデータを得る
	 * 
	 * この戻り値が破棄されるときにRAIIで自動的にロックが解除される。
	 * また、戻り値はロックされた共有資源へ、非共有資源としてアクセス可能な参照として使用できる。
	 */
	auto locked() @safe @property // @suppress(dscanner.confusing.function_attributes)
	{
		lock();
		static struct LockedData
		{
		private:
			T*              _data;
			void delegate() _unlock;
		public:
			ref inout(T) dataRef() inout @property { return *_data; }
			@disable this(this);
			~this() @trusted
			{
				if (_unlock)
					_unlock();
			}
			alias dataRef this;
		}
		return LockedData(&_data, &unlock);
	}
	/// ditto
	auto locked() @trusted shared inout @property
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
	bool tryLock() @safe
	{
		auto tmp = (() @trusted => _mutex.tryLock())();
		// ロックされていなければ _locked を操作することは許されない
		if (tmp)
			_locked++;
		return tmp;
	}
	/// ditto
	bool tryLock() @trusted shared
	{
		return (cast()this).tryLock();
	}
	
	
	/***************************************************************************
	 * ロックする。
	 */
	void lock() @safe
	{
		_mutex.lock();
		_locked++;
	}
	/// ditto
	void lock() @trusted shared
	{
		(cast()this).lock();
	}
	
	
	/***************************************************************************
	 * ロック解除する。
	 */
	void unlock() @safe
	{
		_locked--;
		_mutex.unlock();
	}
	/// ditto
	void unlock() @trusted shared
	{
		(cast()this).unlock();
	}
	
	
	/***************************************************************************
	 * 非共有資源としてアクセスする
	 */
	ref T asUnshared() inout @property
	{
		enforce(_locked != 0);
		return *cast(T*)&_data;
	}
	/// ditto
	ref T asUnshared() shared inout @property
	{
		enforce(_locked != 0);
		return *cast(T*)&_data;
	}
	
	
	/***************************************************************************
	 * 共有資源としてアクセスする
	 */
	ref shared(T) asShared() inout @property
	{
		return *cast(shared(T)*)&_data;
	}
	/// ditto
	ref shared(T) asShared() shared inout @property
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

@system unittest
{
	import core.atomic;
	auto s = managedShared!int();
	s.asUnshared += 50;
	s.asShared.atomicOp!"+="(100);
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
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 353);
}


@system unittest
{
	import core.atomic;
	auto s = new shared ManagedShared!int();
	try
	{
		s.asUnshared += 50;
	}
	catch (Exception e) { }
	assert(s.asShared == 0);
	s.asShared.atomicOp!"+="(100);
	s.lock();
	s.asUnshared += 200;
	assert(s.asShared == 300);
	s.unlock();
	try
	{
		s.asUnshared += 200;
		assert(0);
	}
	catch (Exception e) { }
	assert(s.asShared == 300);
	
	{
		auto ld = s.locked;
		assert(s._locked);
		ld += 1;
	}
	assert(!s._locked);
	assert(s.asShared == 301);
	
	synchronized (s)
	{
		assert(s._locked);
		{
			auto ld = s.locked;
			assert(s._locked);
			ld += 2;
		}
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 303);
}




/*******************************************************************************
 * マルチタスクキューによって管理されるタスクデータ
 */
class TaskData
{
	import std.datetime;
	import std.uuid;
	/// 状態
	enum State
	{
		/// 初期状態で、タスクプールに追加される前
		waiting,
		/// タスクプールに追加された状態
		ready,
		/// 実行中の状態
		running,
		/// 実行が終了した状態
		finished,
		/// 実行の結果、異常終了した状態
		failed,
		/// 実行されずにドロップされた状態
		dropped,
	}
protected:
	/// タスクの種類
	immutable string                 type;
	/// タスクの本体
	immutable void delegate() shared onCall;
	/// Queueに追加された時刻
	shared SysTime                   timCreate;
	/// Poolに追加された時刻
	shared SysTime                   timReady = SysTime.init;
	/// 実行開始した時刻
	shared SysTime                   timStart = SysTime.init;
	/// 実行終了した時刻
	shared SysTime                   timEnd = SysTime.init;
	/// 一意なID
	immutable UUID                   uuid;
	/// 状態
	State state = State.waiting;
	/// Poolに追加されたタイミングでコールバック
	void onReady() shared {  }
	/// 実行開始したタイミングでコールバック
	void onStart() shared {  }
	/// 実行終了したタイミングでコールバック
	void onEnd() shared {  }
	/// 実行失敗したタイミングでコールバック
	void onFailed(Throwable) shared {  }
	/// 実行されずにドロップしたタイミングでコールバック
	void onDropped() shared {  }
	
public:
	///
	this(string ty, void delegate() shared callback, UUID id = randomUUID())
	{
		type      = ty;
		onCall    = callback;
		timCreate = Clock.currTime();
		uuid      = cast(immutable)id;
	}
}

/*******************************************************************************
 * マルチタスクキュー
 * 
 * タスクの待ち行列を作成する。
 * 同じ種類のタスクは待ち行列によって順次実行し、違う種類のタスクはタスクプールで並列実行する。
 * コンストラクタでタスクプールの設定を行い、$(D invoke)関数によってタスクの種類と実行内容を指定する。
 * $(D invoke)により指定されるタスクは、$(D TaskData)クラスを継承することで細かく内容を調整することができる。
 * $(D invoke)によって待ち行列に追加された未だ実行されていないタスクを、$(D drop)によって実行取り消しすることができる。
 * $(D informations)関数により、各タスクの実行状況を調べることができる。
 * 
 * 以下のようなことが可能
 * 
 * <img src="img/voile.sync.MultiTaskQueue-testcase.drawio.svg" />
 */
class MultiTaskQueue
{
private:
	import core.atomic;
	import core.sync.mutex;
	import core.thread;
	import std.concurrency;
	import std.parallelism;
	import std.uuid;
	import std.datetime;
	
	TaskPool _pool;
	void delegate() _finishPool;
	
	struct TaskQueue
	{
	private:
		TaskData[][string] _tasks;
		enum State
		{
			ready, finish
		}
		State _state = State.ready;
	public:
		///
		void pushBack(TaskData task, void delegate() onCreated = null)
		{
			TaskData[] update(ref TaskData[] tasks)
			{
				onCreated = null;
				tasks ~= task;
				return tasks;
			}
			TaskData[] create()
			{
				return [task];
			}
			_tasks.update(task.type, &create, &update);
			if (onCreated !is null)
				onCreated();
		}
		///
		TaskData removeAt(string type, UUID uuid)
		{
			import std.algorithm: countUntil;
			import std.array: replaceInPlace;
			TaskData removed;
			TaskData[] update(ref TaskData[] tasks)
			{
				// 現在実行中のタスクには手を出さない
				if (tasks.length <= 1 || tasks[0].uuid == uuid)
					return tasks;
				auto removeIdx = tasks.countUntil!(e => e.uuid == uuid);
				if (removeIdx == -1)
					return tasks;
				removed = tasks[removeIdx];
				tasks.replaceInPlace(removeIdx, removeIdx+1, TaskData[].init);
				return tasks;
			}
			TaskData[] create()
			{
				return [];
			}
			_tasks.update(type, &create, &update);
			return removed;
		}
		///
		TaskData removeFront(string type)
		{
			TaskData ret;
			TaskData[] update(ref TaskData[] tasks)
			{
				if (tasks.length == 0)
					return tasks;
				ret = tasks[0];
				tasks = tasks[1..$];
				return tasks;
			}
			TaskData[] create()
			{
				return [];
			}
			_tasks.update(type, &create, &update);
			return ret;
		}
		///
		TaskData removeFrontAndGetNext(string type, out TaskData next)
		{
			TaskData ret;
			TaskData[] update(ref TaskData[] tasks)
			{
				if (tasks.length == 0)
					return tasks;
				ret = tasks[0];
				tasks = tasks[1..$];
				if (tasks.length > 0)
					next = tasks[0];
				return tasks;
			}
			TaskData[] create()
			{
				return [];
			}
			_tasks.update(type, &create, &update);
			return ret;
		}
		///
		TaskData refFront(string type)
		{
			import std.exception: enforce;
			return (*enforce(type in _tasks))[0];
		}
		///
		TaskData getFront(string type)
		{
			if (auto p = type in _tasks)
				if ((*p).length > 0)
					return (*p)[0];
			return null;
		}
		///
		TaskData getAt(string type, UUID id)
		{
			if (auto p = type in _tasks)
			{
				import std.algorithm, std.array;
				auto found = (*p).find!(a => a.uuid == id);
				if (!found.empty)
					return found.front;
			}
			return null;
		}
		/// 現在実行中の次のタスクを得る
		TaskData getNext(string type)
		{
			if (auto p = type in _tasks)
				if ((*p).length > 1)
					return (*p)[1];
			return null;
		}
		/// 現在実行中のタスクの次のタスクを破棄する。破棄されたタスクを返す。
		TaskData dropNext(string type)
		{
			import std.array: replaceInPlace;
			if (auto p = type in _tasks)
			{
				if ((*p).length > 1)
				{
					auto ret = (*p)[1];
					replaceInPlace(*p, 1, 2, cast(TaskData[])[]);
					return ret;
				}
			}
			return null;
		}
		///
		string[] types()
		{
			return _tasks.keys;
		}
	}
	shared ManagedShared!TaskQueue _taskQueue;
	
	void _startTask(string type) shared
	{
		void delegate(TaskData p, Throwable e) edTask;
		void delegate(TaskData p) stTask;
		edTask = (TaskData p, Throwable e)
		{
			auto tim = Clock.currTime();
			auto queue = _taskQueue.locked;
			assert(p.timStart.assumeUnshared !is SysTime.init);
			assert(p.timEnd.assumeUnshared    is SysTime.init);
			p.timEnd.assumeUnshared = tim;
			auto sp = cast(shared)p;
			TaskData next;
			auto currTsk = queue.removeFrontAndGetNext(type, next);
			assert(currTsk is p);
			if (e)
			{
				p.state = TaskData.State.failed;
				sp.onFailed(e);
			}
			else
			{
				p.state = TaskData.State.finished;
				sp.onEnd();
			}
			if (next)
				stTask(next);
		};
		stTask = (TaskData p)
		{
			assert(p.timReady.assumeUnshared is SysTime.init);
			assert(p.timStart.assumeUnshared is SysTime.init);
			p.timReady.assumeUnshared = Clock.currTime();
			p.state.assumeUnshared = TaskData.State.ready;
			auto sp = cast(shared)p;
			sp.onReady();
			_pool.assumeUnshared.put(task(
			{
				synchronized (_taskQueue)
				{
					p.state.assumeUnshared = TaskData.State.running;
					p.timStart.assumeUnshared = Clock.currTime();
				}
				sp.onStart();
				try
				{
					sp.onCall();
					edTask(p, null);
				}
				catch (Throwable e)
				{
					edTask(p, e);
				}
			}));
		};
		synchronized (_taskQueue)
			stTask(_taskQueue.asUnshared.refFront(type));
	}
	
	void _initialize(TaskPool pool, void delegate() finishPool)
	{
		_pool          = pool;
		_finishPool    = finishPool;
		_taskQueue     = new shared ManagedShared!TaskQueue;
	}
	
public:
	
	/***************************************************************************
	 * コンストラクタ
	 * 
	 * Params:
	 *      pool = 使用するタスクプールを指定できる
	 *      callbackFinishPool = タスクキューを破棄した際に全てのタスクが終了した際に呼ばれる。タスクプールを終了するために使用できる。
	 *      worker = ワーカースレッド数を指定して作成できる
	 */
	this(TaskPool pool, void delegate() callbackFinishPool = null)
	{
		this._initialize(pool, callbackFinishPool);
	}
	
	/// ditto
	this(TaskPool pool, void delegate() callbackFinishPool = null) shared
	{
		// コンストラクタにおいては、このインスタンスは間違いなく単一であるため
		// unsharedにキャストできる
		(cast()this)._initialize(pool, callbackFinishPool);
	}
	/// ditto
	this(size_t worker = 8, bool daemon = false)
	{
		this(new TaskPool(worker), () => _pool.finish(true));
	}
	/// ditto
	this(size_t worker = 8, bool daemon = false) shared
	{
		this(new TaskPool(worker), () => _pool.assumeUnshared.finish(true));
	}
	
	/***************************************************************************
	 * インスタンスを破棄する。
	 */
	void dispose()
	{
		with (_taskQueue.locked)
		{
			_state = State.finish;
			// 現在実行されていないすべてのデータを破棄
			foreach (ty; types)
			{
				TaskData t = dropNext(ty);
				while (t)
				{
					(cast(shared)t).onDropped();
					t = dropNext(ty);
				}
			}
		}
		if (_finishPool !is null)
			_finishPool();
	}
	
	/***************************************************************************
	 * タスクを実行予約する
	 * 
	 * タスクを待ち行列に追加する。待ち行列に追加されると、順次実行される。
	 * 待ち行列は$(D type)毎にあり、どの待ち行列に追加されるかはタスクの$(D type)により決まる。
	 * 同じ$(D type)では、追加された順に順次実行される。
	 * 異なる$(D type)の場合は並行して実行される。並行数はコンストラクタで指定したタスクプールに依存する。
	 * 
	 * Params:
	 *      tsk = タスクデータを指定する
	 *      type = タスク種別を指定する
	 *      dg = タスクの処理内容のデリゲートを指定する
	 *      id = タスクの識別用IDを指定する
	 * Returns:
	 *      タスクを追加することができたらtrueを、追加できなかったらfalseを返す。
	 */
	bool invoke(TaskData tsk)
	{
		with (_taskQueue.locked)
		{
			if (_state == State.ready)
			{
				pushBack(tsk);
				auto frontTask = refFront(tsk.type);
				if (frontTask.uuid == tsk.uuid)
					(cast(shared)this)._startTask(tsk.type);
				return true;
			}
		}
		return false;
	}
	/// ditto
	bool invoke(TaskData tsk) shared
	{
		// どちらもやることは同じ
		return (cast()this).invoke(tsk);
	}
	/// ditto
	bool invoke(string type, void delegate() shared dg, UUID id = randomUUID())
	{
		return invoke(new TaskData(type, dg, id));
	}
	/// ditto
	bool invoke(string type, void delegate() shared dg, UUID id = randomUUID()) shared
	{
		return invoke(new TaskData(type, dg, id));
	}
	
	/***************************************************************************
	 * タスク実行を取りやめる
	 * 
	 * タスクがまだ実行されていない場合は、実行を取りやめる。
	 */
	void drop(string type, UUID id)
	{
		with (_taskQueue.locked)
		{
			if (_state == State.ready)
				removeAt(type, id);
		}
	}
	
	/***************************************************************************
	 * タスクの情報
	 */
	struct TaskInfo
	{
		/// タスクの種類
		string         type;
		/// Queueに追加された時刻
		SysTime        timCreate;
		/// Poolに追加された時刻
		SysTime        timReady;
		/// 実行開始した時刻
		SysTime        timStart;
		/// 実行終了した時刻
		SysTime        timEnd;
		/// 一意なID
		UUID           uuid;
		/// タスクの状態
		alias State = TaskData.State;
		/// ditto
		State state;
	}
	
	/***************************************************************************
	 * 情報取得
	 * 
	 * タスクの実行状況を調べる。
	 * 
	 * Returns:
	 *      タスクの情報を$(D TaskInfo)の配列で返す。
	 */
	TaskInfo[] informations() const @safe @property
	{
		TaskInfo[] ret;
		with (_taskQueue.locked)
		{
			foreach (k, tasks; _tasks)
			{
				foreach (t; tasks)
					ret ~= TaskInfo(t.type, t.timCreate, t.timReady, t.timStart, t.timEnd, t.uuid, t.state);
			}
		}
		return ret;
	}
}

// <img src="img/voile.sync.MultiTaskQueue-testcase.drawio.svg" />
@system unittest
{
	import std;
	auto pool = new TaskPool(2);
	pool.isDaemon = true;
	auto mtq = new MultiTaskQueue(pool, () => pool.finish(false));
	scope (exit)
		mtq.dispose();
	UUID[][4] ids;
	
	class MyTaskData: TaskData
	{
		SyncEvent ended;
		SyncEvent started;
		SyncEvent kill;
		bool      fail;
		this(int grp, UUID id)
		{
			started = new SyncEvent(false);
			ended   = new SyncEvent(false);
			kill    = new SyncEvent(false);
			super(grp.text, &(cast(shared)this).onRun, id);
		}
		void onRun() shared
		{
			started.assumeUnshared.signaled = true;
			kill.assumeUnshared.wait();
			enforce(!fail);
		}
		override void onEnd() shared
		{
			ended.assumeUnshared.signaled = true;
		}
		override void onFailed(Throwable e) shared
		{
			ended.assumeUnshared.signaled = true;
		}
	}
	MyTaskData[][4] tasks;
	MyTaskData currentTask(size_t grp)
	{
		return cast(MyTaskData) mtq._taskQueue.locked.getFront(grp.text);
	}
	MyTaskData getTask(size_t grp, size_t idx)
	{
		return tasks[grp][idx];
	}
	size_t currentIdx(size_t grp)
	{
		if (auto tsk = currentTask(grp))
			return ids[grp].countUntil(tsk.uuid.assumeUnshared);
		return -1;
	}
	void wait(size_t grp)
	{
		currentTask(grp).started.wait();
	}
	void start(int grp)
	{
		auto id = randomUUID();
		auto tsk = new MyTaskData(grp, id);
		mtq.invoke(tsk);
		tasks[grp] ~= tsk;
		ids[grp]   ~= id;
	}
	void end(size_t grp)
	{
		auto tsk = currentTask(grp);
		tsk.kill.signaled = true;
		tsk.ended.wait();
	}
	void fail(size_t grp)
	{
		auto tsk = currentTask(grp);
		tsk.fail = true;
		tsk.kill.signaled = true;
		tsk.ended.wait();
	}
	void drop(size_t grp, size_t idx)
	{
		mtq.drop(grp.text, ids[grp][idx]);
	}
	
	
	start(1);
	start(2);
	start(3);
	
	wait(1);
	wait(2);
	
	// チェック1：ワーカースレッド以上の処理は動かさない
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(1) == 0);
		assert(currentIdx(2) == 0);
		assert(currentIdx(3) == 0);
		assert(getFront("1").state == TaskData.State.running);
		assert(getFront("2").state == TaskData.State.running);
		assert(getFront("3").state == TaskData.State.ready);
	}
	
	auto infos = mtq.informations;
	infos.sort!((a,b) => icmp(a.type, b.type) < 0, SwapStrategy.stable);
	assert(infos.length == 3);
	assert(infos[0].type == "1");
	assert(infos[1].type == "2");
	assert(infos[2].type == "3");
	assert(infos[0].state == TaskData.State.running);
	assert(infos[1].state == TaskData.State.running);
	assert(infos[2].state == TaskData.State.ready);
	
	end(1);
	wait(3);
	
	// チェック2：ワーカーが空くと自動でキューが消費される
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(1) == -1);
		assert(currentIdx(2) == 0);
		assert(currentIdx(3) == 0);
		assert(getFront("1") is null);
		assert(getFront("2").state == TaskData.State.running);
		assert(getFront("3").state == TaskData.State.running);
	}
	
	start(2);
	end(3);
	
	// チェック3：ワーカーが開いても前処理が終わっていないとキューは消費されない
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(2) == 0);
		assert(getAt("2", ids[2][1]).state == TaskData.State.waiting);
	}
	
	end(2);
	wait(2);
	
	// チェック4：前処理が終わるとキューが消費される
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(2) == 1);
		assert(getAt("2", ids[2][1]).state == TaskData.State.running);
	}
	
	
	start(3);
	start(3);
	start(3);
	drop(3, 2);
	wait(3);
	
	// チェック5：タスクをドロップする
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(3) == 1);
		assert(getAt("3", ids[3][1]).state == TaskData.State.running);
		assert(getAt("3", ids[3][2]) is null);
		assert(getAt("3", ids[3][3]).state == TaskData.State.waiting);
	}
	
	end(2);
	end(3);
	wait(3);
	
	// チェック6：ドロップされたタスクは実行されない
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(3) == 3);
		assert(getAt("3", ids[3][1]) is null);
		assert(getAt("3", ids[3][2]) is null);
		assert(getAt("3", ids[3][3]).state == TaskData.State.running);
	}
	fail(3);
	
	// チェック7：タスクの失敗がわかる
	with (mtq._taskQueue.locked)
	{
		assert(currentIdx(3) == -1);
		assert(getAt("3", ids[3][3]) is null);
		assert(getTask(3, 3).state == TaskData.State.failed);
	}
}
