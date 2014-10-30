This directory contains the automated test suite of the fbclient Lua package.

Windows 32bit platforms
-----------------------

Download and install the binaries:

	download http://fbclient.googlecode.com/files/fbclient-unit-tests-win32.zip and unzip it in this directory
	> cd win32
	win32> install_servers.bat

The installer will install multiple instances of Firebird server, one of each version
configured to listen on 127.0.0.1 port 3205, 3206, 3213, ... respectively, analogous
server's version number.

Firebird binaries were downloaded from the firebirdsql.org website.

Lua C modules were compiled using LuaRocks in a Visual C++ 2010 environment.
It is recommended that you compile them yourself on your own machine
and replace them if possible, just in case I have a virus on my computer
that I am unaware of.

Run the test script (the bat will use the bundled Lua interpreter):

	> run_test_file.bat test_all.lua

Running individual test files is not supported. Modify test_all.lua instead.

When you're done testing:

	> cd win32
	win32> uninstall_servers.bat

Linux platforms
---------------

Install Lua packages loop, alien, lua-ex.
If you want to test bignum support, install Lua packages ldecnumber, lbc, lmapm.
* Note: lbc is not compiling for me on linux 64bit.
a) linux 32bit: install firebird test servers:
  - download http://fbclient.googlecode.com/files/fbclient-unit-tests-linux32.tar.gz
  - untar it into this directory, cd into linux32 directory and run ./install_servers.sh
b) linux 64bit: install firebird test servers:
  - download http://fbclient.googlecode.com/files/fbclient-unit-tests-linux64.tar.gz
  - untar it into this directory, cd into linux64 directory and run ./install_servers.sh
Run test_all.lua. Running individual test files is not supported. Modify test_all.lua instead.
When you're done testing, run ./uninstall_servers.sh.

