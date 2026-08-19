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

#include "stdafx.h"
#include "BreakPoint.hpp"

#include "CppCoverageException.hpp"
#include "Address.hpp"

#include "Tools/Log.hpp"
#include "Tools/ProcessMemory.hpp"

namespace CppCoverage
{
	using Addresses = std::vector<DWORD64>;
	using AddressesIt = Addresses::const_iterator;

	//-------------------------------------------------------------------------
	void SetBreakPointsRange(HANDLE hProcess,
	                         AddressesIt begin,
	                         AddressesIt end,
	                         BreakPoint::InstructionCollection& oldInstructions)
	{
		if (begin == end)
			return;

		const auto firstValue = *begin;
		auto memorySpaceSize =
		    *(end - 1) - firstValue + BreakPoint::breakPointInstruction.size();
		auto firstAddress = reinterpret_cast<void*>(firstValue);
		auto buffer = Tools::ReadProcessMemory(
		    hProcess, firstAddress, static_cast<size_t>(memorySpaceSize));

		for (auto it = begin; it < end; ++it)
		{
			auto index = static_cast<size_t>(*it - firstValue);
			BreakPoint::Instruction oldInstruction;
			std::copy_n(buffer.begin() + index,
			            oldInstruction.size(),
			            oldInstruction.begin());
			std::copy(BreakPoint::breakPointInstruction.begin(),
			          BreakPoint::breakPointInstruction.end(),
			          buffer.begin() + index);
			oldInstructions.emplace_back(oldInstruction, *it);
		}
		Tools::WriteProcessMemory(
		    hProcess, firstAddress, &buffer[0], buffer.size());
	}

#ifdef _M_ARM64
	const BreakPoint::Instruction BreakPoint::breakPointInstruction{
	    0x00, 0x00, 0x3E, 0xD4}; // BRK #0xF000
#else
	const BreakPoint::Instruction BreakPoint::breakPointInstruction{0xCC};
#endif

	//-------------------------------------------------------------------------
	BreakPoint::InstructionCollection
	BreakPoint::SetBreakPoints(HANDLE hProcess, Addresses&& addresses) const
	{
		InstructionCollection oldInstructions;

		std::sort(addresses.begin(), addresses.end());
		addresses.erase(std::unique(addresses.begin(), addresses.end()),
		                addresses.end());

#ifdef _M_ARM64
		for (auto address : addresses)
		{
			if (address % breakPointInstruction.size() != 0)
				THROW("ARM64 breakpoint address is not instruction-aligned.");
		}
#endif

		auto beginRange = addresses.cbegin();

		for (auto it = beginRange; it < addresses.cend(); ++it)
		{
			if (*it - *beginRange + breakPointInstruction.size() > 4096)
			{
				SetBreakPointsRange(hProcess, beginRange, it, oldInstructions);
				beginRange = it;
			}
		}
		SetBreakPointsRange(
		    hProcess, beginRange, addresses.end(), oldInstructions);

		return oldInstructions;
	}

	//-------------------------------------------------------------------------
	void BreakPoint::RemoveBreakPoint(const Address& address,
	                                  const Instruction& oldInstruction) const
	{
		Tools::WriteProcessMemory(address.GetProcessHandle(),
		                          address.GetValue(),
		                          oldInstruction.data(),
		                          oldInstruction.size());
	}

	//-------------------------------------------------------------------------
	void BreakPoint::SetInstructionPointer(HANDLE hThread, void* address) const
	{
		CONTEXT context{};
		context.ContextFlags = CONTEXT_CONTROL;
		if (!GetThreadContext(hThread, &context))
			THROW_LAST_ERROR("Error in GetThreadContext", GetLastError());

#if defined(_M_ARM64)
		context.Pc = reinterpret_cast<DWORD64>(address);
#elif defined(_WIN64)
		context.Rip = reinterpret_cast<DWORD64>(address);
#else
		context.Eip = static_cast<DWORD>(reinterpret_cast<DWORD_PTR>(address));
#endif
		if (!SetThreadContext(hThread, &context))
			THROW_LAST_ERROR("Error in SetThreadContext", GetLastError());
	}
}
