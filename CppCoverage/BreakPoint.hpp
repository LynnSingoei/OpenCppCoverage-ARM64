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

#include <array>
#include <utility>
#include <vector>
#include <Windows.h>
#include "CppCoverageExport.hpp"

namespace CppCoverage
{
	class Address;

#ifdef _M_ARM64
	using BreakPointInstruction = std::array<unsigned char, 4>;
#else
	using BreakPointInstruction = std::array<unsigned char, 1>;
#endif

	class CPPCOVERAGE_DLL BreakPoint
	{
	  public:
		BreakPoint() = default;

		using Instruction = BreakPointInstruction;
		static const Instruction breakPointInstruction;

		void RemoveBreakPoint(const Address&,
		                      const Instruction& oldInstruction) const;

		using InstructionCollection =
		    std::vector<std::pair<Instruction, DWORD64>>;

		InstructionCollection
		SetBreakPoints(HANDLE hProcess, std::vector<DWORD64>&& addresses) const;

		void SetInstructionPointer(HANDLE hThread, void* address) const;

	  private:
		BreakPoint(const BreakPoint&) = delete;
		BreakPoint& operator=(const BreakPoint&) = delete;
	};
}
