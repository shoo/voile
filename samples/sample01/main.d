module main;

import std.range, std.algorithm, std.array, std.format;
import voile.stm, voile.handler;

///
interface TestFlow
{
	///
	TestFlow update();
}
///
class BaseTestFlow: ProcessFlow!TestFlow
{
	///
	abstract string name() const @property;
}

///
class Child1Stm: BaseTestFlow
{
private:
	mixin(parseCsvStm(import("child1.stm.csv"), import("child1.map.csv")));
	Event[][] _stepData;
	Event[] _step;
public:
	///
	Stm!(State, Event) _stm;
	/// ditto
	alias _stm this;
	///
	this()
	{
		_stm = stmFactory();
		_stm.consumeMode(ConsumeMode.separate);
		with (Event)
			_stepData = [[b],[b]];
	}
	///
	void initialize()
	{
		_step = _stepData.front;
		_stepData.popFront();
	}
	///
	override TestFlow update()
	{
		if (emptyEvents)
		{
			_stm.put(_step.front);
			_step.popFront();
		}
		consume();
		return super.update();
	}
	///
	override string name() const @property
	{
		return _stm.name;
	}
}

///
class Child2Stm: BaseTestFlow
{
private:
	mixin(parseCsvStm(import("child2.stm.csv"), import("child2.map.csv")));
	Event[][] _stepData;
	Event[] _step;
public:
	///
	Stm!(State, Event) _stm;
	/// ditto
	alias _stm this;
	///
	this()
	{
		_stm = stmFactory();
		_stm.consumeMode(ConsumeMode.separate);
		with (Event)
			_stepData = [[b],[a]];
	}
	///
	void initialize()
	{
		_step = _stepData.front;
		_stepData.popFront();
	}
	///
	override TestFlow update()
	{
		if (emptyEvents)
		{
			_stm.put(_step.front);
			_step.popFront();
		}
		consume();
		return super.update();
	}
	///
	override string name() const @property
	{
		return _stm.name;
	}
}

class MainStm: BaseTestFlow
{
private:
	Child1Stm _child1;
	Child2Stm _child2;
	
	mixin(parseCsvStm(import("main.stm.csv"), import("main.map.csv")));
	Event[] _step;
public:
	///
	Stm!(State, Event) _stm;
	/// ditto
	alias _stm this;
	///
	Handler!(void delegate()) onError;
	///
	Appender!string message;
	///
	this()
	{
		_stm = stmFactory();
		_stm.consumeMode(ConsumeMode.separate);
		_child1 = new Child1Stm;
		_child2 = new Child2Stm;
		import std.stdio;
		void setMsgEv(Stm, Ev)(Stm stm, Ev e)
		{
			message.formattedWrite(
				"[%s-%s]onEvent:%s(%s)\n",
				stm.name, stm.stateNames[stm.currentState], stm.eventNames[e], e);
		}
		void setMsgSt(Stm, St)(Stm stm, St oldSt, St newSt)
		{
			message.formattedWrite(
				"[%s-%s]onStateChanged:%s(%s)->%s(%s)\n",
				stm.name, stm.stateNames[stm.currentState], stm.stateNames[oldSt], oldSt, stm.stateNames[newSt], newSt);
		}
		void setMsgEntCh(StmP, StmC)(StmP p, StmC c)
		{
			message.formattedWrite("[%s-%s]onEnterChild:>>>%s\n", p.name, p.stateNames[p.currentState], c.name);
		}
		void setMsgExitCh(StmP, StmC)(StmP p, StmC c)
		{
			message.formattedWrite("[%s-%s]onExitChild:<<<%s\n", p.name, p.stateNames[p.currentState], c.name);
		}
		
		onEvent                ~= (Event e)                  { setMsgEv(this, e); };
		onStateChanged         ~= (State oldSt, State newSt) { setMsgSt(this, oldSt, newSt); };
		onEnterChild           ~= (TestFlow child)           { setMsgEntCh(this, cast(BaseTestFlow)child); };
		onExitChild            ~= (TestFlow child)           { setMsgExitCh(this, cast(BaseTestFlow)child); };
		
		_child1.onEvent        ~= (Child1Stm.Event e)        { setMsgEv(_child1, e); };
		_child1.onStateChanged ~= (Child1Stm.State oldSt, Child1Stm.State newSt) { setMsgSt(_child1, oldSt, newSt); };
		
		_child2.onEvent        ~= (Child2Stm.Event e)        {setMsgEv(_child2, e); };
		_child2.onStateChanged ~= (Child2Stm.State oldSt, Child2Stm.State newSt) { setMsgSt(_child2, oldSt, newSt); };
		
		onError     ~= ()
		{
			put(_stm, Event.test);
			// 終了
			setNextFlow(null);
		};
		_child1.onExit ~= () { _stm.put(Event.stm1exit); };
		_child2.onExit ~= ()
		{
			if (_child2.currentState == _child2.State.init)
			{
				_stm.put(Event.stm2exit);
			}
			else
			{
				_stm.put(Event.stm2err);
			}
		};
		
		initialize();
	}
	///
	void initialize()
	{
		with (Event)
			_step = [test, test];
	}
	///
	override TestFlow update()
	{
		if (emptyEvents)
		{
			_stm.put(_step.front);
			_step.popFront();
		}
		consume();
		return super.update();
	}
	///
	override string name() const @property
	{
		return _stm.name;
	}
	///
	override string toString() const
	{
		return message.data;
	}
}

void main()
{
	import std.stdio;
	auto stm = new MainStm;
	TestFlow flow;
	auto stFlow = new StateFlow!TestFlow(stm);
	stFlow.onEnterChild ~= (TestFlow parent, TestFlow child)
	{
		auto p = cast(BaseTestFlow)parent;
		auto c = cast(BaseTestFlow)child;
	};
	stFlow.onExitChild ~= (TestFlow parent, TestFlow child)
	{
		auto p = cast(BaseTestFlow)parent;
		auto c = cast(BaseTestFlow)child;
	};
	while (stFlow.current)
	{
		stFlow.update();
	}
	
	assert(stm.toString() == import("result.txt"));
}
