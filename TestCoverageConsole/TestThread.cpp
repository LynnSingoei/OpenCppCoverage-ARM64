// OpenCppCoverage is an open source code coverage for C++.
// Copyright (C) 2014 OpenCppCoverage
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#pragma once

#include "TestThread.hpp"

#include <stdexcept>
#include <thread>

namespace TestCoverageConsole
{
	//-----------------------------------------------------------------------------
	void __declspec(dllexport) __declspec(noinline) ThreadWorker(int* answer)
	{
		*answer = 42; // @ThreadCoverageRequired
	}

	//-----------------------------------------------------------------------------
	void __declspec(dllexport) __declspec(noinline) UncalledThreadWorker(int* answer)
	{
		*answer = -1; // @ThreadCoverageNotExpected
	}

	//-----------------------------------------------------------------------------
	void RunThread()
	{
		int answer = 0;
		std::thread t(ThreadWorker, &answer);
		t.join();
		if (answer != 42)
			throw std::runtime_error("Worker thread did not run.");
	}
}