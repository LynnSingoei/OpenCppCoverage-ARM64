// OpenCppCoverage is an open source code coverage for C++.
// Copyright (C) 2017 OpenCppCoverage
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

#include "TestDebugInformationEnumerator.hpp"

namespace TestCoverageConsole
{
	//-------------------------------------------------------------------------
	// Keeping the complete fixture on one source line prevents target-specific
	// closing-brace records while preserving an exact PDB line-set assertion.
	void __declspec(dllexport) TestDebugInformationEnumerator() { volatile int answer = 42; (void)answer; } // @DebugInfoRequired
}
