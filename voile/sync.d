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
	import core.sys.windows.windows;
}
import std.traits, std.parallelism;

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
		void wait() nothrow @nogc
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
		bool wait(Duration dir) nothrow @nogc
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





/***************************************************************************
 * タスクを生成する
 */
private void _makeTask(alias func, Fut, Args...)(Fut future, Args args)
{
	alias Ret = Fut.ResultType;
	synchronized (future)
	{
		future._type = Fut.FinishedType.none;
		future._resultException = null;
	}
	future._task = task({
		future._evStart.signaled = true;
		try
		{
			static if (is(Ret == void))
			{
				bool call;
				func(args);
				synchronized (future)
				{
					future._type = Fut.FinishedType.done;
					call = future._onFinished !is null;
				}
				if (call)
					future._onFinished();
				return;
			}
			else
			{
				bool call;
				future._resultRaw() = func(args);
				synchronized (future)
				{
					future._type = Fut.FinishedType.done;
					call = future._onFinished !is null;
				}
				if (call)
					future._onFinished(future._resultRaw);
				return future._resultRaw;
			}
		}
		catch (Exception e)
		{
			bool call;
			synchronized (future)
			{
				call = future._onFailed !is null;
				future._type = Fut.FinishedType.failed;
			}
			if (call)
				future._onFailed(e);
			throw e;
		}
		catch (Throwable e)
		{
			bool call;
			synchronized (future)
			{
				if (future._onFailed !is null)
					call = true;
				future._type = Fut.FinishedType.fatal;
			}
			if (call)
				future._onFatalError(e);
			throw e;
		}
		assert(0);
	});
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
private:
	
	CallbackType               _onFinished;
	void delegate(Exception e) _onFailed;
	void delegate(Throwable e) _onFatalError;
	TaskType                   _task;
	TaskPool                   _taskPool;
	SyncEvent                  _evStart;
	
	enum FinishedType
	{
		none, done, failed, fatal
	}
	
	FinishedType _type;
	union
	{
		Exception _resultException;
		Throwable _resultFatalError;
	}
	
	static if (!is(Ret == void))
	{
		ref inout(ResultType) _resultRaw() inout @property
		{
			return *cast(inout(ResultType)*)&(cast(Future)this)._task.fixRef((cast(Future)this)._task.returnVal);
		}
	}
	
public:
	this()
	{
		_evStart = new SyncEvent(false);
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
	
	/***************************************************************************
	 * チェーン
	 */
	auto then(Ret2)(TaskPool pool,
		Ret2 delegate(ResultType) callbackFinished,
		void delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (!is(Ret == void) && is(typeof(callbackFinished(_resultRaw))))
	{
		auto ret = new Future!Ret2;
		onFinished   = (ref ResultType result) { ret.perform(pool, callbackFinished, result); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/// ditto
	auto then(Ret2)(
		Ret2 delegate(ResultType) callbackFinished,
		void delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (!is(Ret == void) && is(typeof(callbackFinished(_resultRaw))))
	{
		auto ret = new Future!Ret2;
		onFinished   = (ref ResultType result){ ret.perform(callbackFinished, result); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(TaskPool pool,
		void delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (!is(Ret == void) && is(typeof(func(_resultRaw))) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func(_resultRaw)));
		onFinished   = (ref ResultType result) { ret.perform!func(pool, result); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(
		void delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (!is(Ret == void) && is(typeof(func(_resultRaw))) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func(_resultRaw)));
		onFinished   = (ref ResultType result) { ret.perform!func(result); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/// ditto
	auto then(Ret2)(TaskPool pool,
		Ret2 delegate() callbackFinished,
		void delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (is(Ret == void) && is(typeof(callbackFinished())))
	{
		auto ret = new Future!Ret2;
		onFinished   = () { ret.perform(pool, callbackFinished); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/// ditto
	auto then(Ret2)(
		Ret2 delegate() callbackFinished,
		void delegate(Exception e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (is(Ret == void) && is(typeof(callbackFinished())))
	{
		auto ret = new Future!Ret2;
		onFinished   = (){ ret.perform(callbackFinished); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(TaskPool pool,
		void delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (is(Ret == void) && is(typeof(func())) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func()));
		onFinished   = () { ret.perform!func(pool); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/// ditto
	auto then(alias func, Ex = Exception)(
		void delegate(Ex e) callbackFailed = null,
		void delegate(Throwable e) callbackFatalError = null)
		if (is(Ret == void) && is(typeof(func())) && is(Ex == Exception))
	{
		auto ret = new Future!(typeof(func()));
		onFinished   = () { ret.perform!func(); };
		onFailed     = callbackFailed;
		onFatalError = callbackFatalError;
		return ret;
	}
	/***************************************************************************
	 * 終了したら呼ばれる
	 */
	void onFinished(CallbackType dg) @property
	{
		bool call;
		synchronized (this)
		{
			if (_type == FinishedType.done && dg !is null)
				call = true;
			_onFinished = dg;
		}
		static if (is(Ret == void))
		{
			if (call)
				_onFinished();
		}
		else
		{
			if (call)
				_onFinished(_resultRaw);
		}
	}
	
	/***************************************************************************
	 * 例外が発生したら呼ばれる
	 */
	void onFailed(void delegate(Exception e) dg) @property
	{
		bool call;
		synchronized (this)
		{
			if (_type == FinishedType.failed && dg is null && _resultException)
				call = true;
			_onFailed = dg;
		}
		if (call)
			_onFailed(_resultException);
	}
	
	
	/***************************************************************************
	 * 致命的エラーが発生したら呼ばれる
	 */
	void onFatalError(void delegate(Throwable e) dg) @property
	{
		bool call;
		synchronized (this)
		{
			if (_type == FinishedType.fatal && dg is null && _resultFatalError)
				call = true;
			_onFatalError = dg;
		}
		if (call)
			_onFatalError(_resultFatalError);
	}
	
	/***************************************************************************
	 * 終了するまで待機する
	 */
	void join()
	{
		_evStart.wait();
		_task.yieldForce();
	}
	
	
	/***************************************************************************
	 * 結果を受け取る
	 */
	ref ResultType yieldForce()
	{
		_evStart.wait();
		return _task.yieldForce();
	}
	
	/// ditto
	ref ResultType workForce()
	{
		_evStart.wait();
		return _task.workForce();
	}
	
	/// ditto
	ref ResultType spinForce()
	{
		_evStart.wait();
		return _task.spinForce();
	}
	
	static if (!is(Ret == void))
	{
		/// ditto
		ref inout(ResultType) result() inout @property
		{
			import std.exception;
			enforce((cast(Future)this)._task.done);
			return _resultRaw();
		}
	}
	
}

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


/*******************************************************************************
 * 非同期処理の開始
 */
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
			T*              _data;
			void delegate() _unlock;
			ref inout(T) _dataRef() inout @property { return *_data; }
		public:
			@disable this(this);
			~this()
			{
				if (_unlock)
					_unlock();
			}
			alias _dataRef this;
		}
		return LockedData(&_data, &unlock);
	}
	/// ditto
	auto locked() shared inout @property
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
		import std.stdio;
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 353);
}


@system unittest
{
	import core.atomic;
	auto s = new shared ManagedShared!int();
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
		import std.stdio;
		assert(s._locked);
	}
	assert(!s._locked);
	assert(s.asShared == 353);
}

private template AssumedUnsharedType(T)
{
	static if (is(T U == shared(U)))
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(U);
	}
	else static if (is(T U == const(shared(U))))
	{
		alias AssumedUnsharedType = const(AssumedUnsharedType!(U));
	}
	else static if (isPointer!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(pointerTarget!T)*;
	}
	else static if (isDynamicArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ForeachType!T)[];
	}
	else static if (isStaticArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ForeachType!T)[T.length];
	}
	else static if (isAssociativeArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ValueType!T)[AssumedUnsharedType!(KeyType!T)];
	}
	else
	{
		alias AssumedUnsharedType = T;
	}
}

auto ref assumeUnshared(T)(ref T x) @property
{
	return *cast(AssumedUnsharedType!(T)*)&x;
}
