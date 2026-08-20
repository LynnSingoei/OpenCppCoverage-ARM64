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

#include "stdafx.h"

#include "CppCoverage/BreakPoint.hpp"
#include "CppCoverage/Address.hpp"
#include "CppCoverage/CppCoverageException.hpp"
#include <random>

using CppCoverage::BreakPoint;

namespace CppCoverageTest
{
	namespace
	{
		using Instruction = BreakPoint::Instruction;

		//-------------------------------------------------------------------------
		std::set<size_t> GetRandomIndexes(int count, int maxValue)
		{
			std::mt19937 gen;
			std::uniform_int_distribution<> dis(0, maxValue);
			std::set<size_t> indexes;

			while (indexes.size() < static_cast<size_t>(count))
				indexes.insert(dis(gen));
			return indexes;
		}

		//---------------------------------------------------------------------
		std::vector<Instruction> GenerateValues(int valueCount,
		                                        int moduloValue)
		{
			std::vector<Instruction> values(valueCount);

			for (auto i = 0; i < valueCount; ++i)
			{
				for (size_t byte = 0; byte < values[i].size(); ++byte)
					values[i][byte] =
					    static_cast<unsigned char>((i + byte) % moduloValue);
			}
			return values;
		}

		//---------------------------------------------------------------------
		std::map<DWORD64, Instruction> BuildOldInstructionsMap(
		    BreakPoint::InstructionCollection& oldInstructionCollection,
		    const std::vector<DWORD64>& addresses)
		{
			std::set<DWORD64> addressesSet{addresses.begin(), addresses.end()};
			std::map<DWORD64, Instruction> oldInstructionsMap;

			for (const auto& pair : oldInstructionCollection)
			{
				oldInstructionsMap.emplace(pair.second, pair.first);
				if (addressesSet.erase(pair.second) != 1)
					throw std::runtime_error("Cannot found address");
			}
			if (!addressesSet.empty())
				throw std::runtime_error("Some addresses are not found");
			return oldInstructionsMap;
		}

		//---------------------------------------------------------------------
		template <typename T>
		DWORD64 ToDWORD64(const T* address)
		{
			return reinterpret_cast<DWORD64>(address);
		}
	}

	//-------------------------------------------------------------------------
	TEST(BreakPointTest, SetBreakPoints)
	{
		BreakPoint breakPoint;

		auto values = GenerateValues(20000, 100);
		auto randomIndexes = GetRandomIndexes(100, static_cast<int>(values.size() - 1));

		std::vector<DWORD64> addresses;
		for (auto index : randomIndexes)
			addresses.push_back(ToDWORD64(&values[index]));

		auto oldInstructionCollection = breakPoint.SetBreakPoints(
		    GetCurrentProcess(), std::move(addresses));
		auto oldInstructionsMap =
		    BuildOldInstructionsMap(oldInstructionCollection, addresses);

		for (size_t i = 0; i < values.size(); ++i)
		{
			auto address = ToDWORD64(&values[i]);
			auto it = oldInstructionsMap.find(address);

			if (it != oldInstructionsMap.end())
			{
				ASSERT_EQ(BreakPoint::breakPointInstruction, values[i]);
				for (size_t byte = 0; byte < it->second.size(); ++byte)
				{
					ASSERT_EQ((i + byte) % 100, it->second[byte]);
				}
			}
			else
			{
				for (size_t byte = 0; byte < values[i].size(); ++byte)
					ASSERT_EQ((i + byte) % 100, values[i][byte]);
			}
		}
	}

	//-------------------------------------------------------------------------
	TEST(BreakPointTest, SetBreakPointsSingle)
	{
		CppCoverage::BreakPoint breakPoint;
		Instruction value;
		value.fill(42);

		auto oldInstructionCollection =
		    breakPoint.SetBreakPoints(GetCurrentProcess(), {ToDWORD64(&value)});

		ASSERT_EQ(1, oldInstructionCollection.size());
		ASSERT_EQ(BreakPoint::breakPointInstruction, value);
		Instruction expected;
		expected.fill(42);
		ASSERT_EQ(expected, oldInstructionCollection.at(0).first);
		ASSERT_EQ(ToDWORD64(&value), oldInstructionCollection.at(0).second);
	}

	//-------------------------------------------------------------------------
	TEST(BreakPointTest, RemovesDuplicateAddresses)
	{
		BreakPoint breakPoint;
		Instruction value;
		value.fill(42);
		const auto address = ToDWORD64(&value);

		auto oldInstructions = breakPoint.SetBreakPoints(
		    GetCurrentProcess(), {address, address});

		ASSERT_EQ(1, oldInstructions.size());
		ASSERT_EQ(BreakPoint::breakPointInstruction, value);
	}

	//-------------------------------------------------------------------------
	TEST(BreakPointTest, RestoresCompleteInstruction)
	{
		BreakPoint breakPoint;
		Instruction value;
		value.fill(42);
		const auto original = value;
		CppCoverage::Address address{
		    GetCurrentProcess(), reinterpret_cast<void*>(&value)};

		auto oldInstructions = breakPoint.SetBreakPoints(
		    GetCurrentProcess(), {ToDWORD64(&value)});
		breakPoint.RemoveBreakPoint(address, oldInstructions.at(0).first);

		ASSERT_EQ(original, value);
	}

	//-------------------------------------------------------------------------
	TEST(BreakPointTest, SetsBreakPointsAcrossReadRanges)
	{
		BreakPoint breakPoint;
		std::vector<Instruction> values(4097);
		for (auto& value : values)
			value.fill(42);
		const auto secondIndex =
		    4096 / BreakPoint::breakPointInstruction.size();

		auto oldInstructions = breakPoint.SetBreakPoints(
		    GetCurrentProcess(),
		    {ToDWORD64(&values.front()), ToDWORD64(&values.at(secondIndex))});

		ASSERT_EQ(2, oldInstructions.size());
		ASSERT_EQ(BreakPoint::breakPointInstruction, values.front());
		ASSERT_EQ(BreakPoint::breakPointInstruction, values.at(secondIndex));
	}

#ifdef _M_ARM64
	//-------------------------------------------------------------------------
	TEST(BreakPointTest, RejectsUnalignedArm64Address)
	{
		CppCoverage::BreakPoint breakPoint;
		std::array<unsigned char, 8> values{};

		ASSERT_THROW(
		    breakPoint.SetBreakPoints(
		        GetCurrentProcess(), {ToDWORD64(values.data() + 1)}),
		    CppCoverage::CppCoverageException);
	}
#endif
}