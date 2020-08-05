import std;

import voile.munion;


void main()
{
	alias TU = TaggedUnion!(int, long, string);
	
	TU dat;
	dat.set!0 = 10;
	assert(dat.get!0 == 10);
	
	assert(dat.match!(
		(int x) => x,
		(long x) => cast(int)x,
		(string x) => x.to!int()) == 10);
	
}
