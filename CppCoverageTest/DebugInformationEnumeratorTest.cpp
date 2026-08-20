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

#include <algorithm>
#include <fstream>

#include "CppCoverage/DebugInformationEnumerator.hpp"
#include "TestCoverageConsole/TestDebugInformationEnumerator.hpp"
#include "TestCoverageConsole/TestCoverageConsole.hpp"

namespace CppCoverageTest
{
	namespace
	{
		struct DebugInformationHandlerMock
		    : CppCoverage::IDebugInformationHandler
		{
			//--------------------------------------------------------------------------
			explicit DebugInformationHandlerMock(
			    const std::filesystem::path& selectedFilename)
			    : selectedFilename_{selectedFilename}
			{
			}

			//--------------------------------------------------------------------------
			bool IsSourceFileSelected(
			    const std::filesystem::path& sourceFile) override
			{
				return selectedFilename_ == sourceFile.filename();
			}

			//--------------------------------------------------------------------------
			void OnSourceFile(const std::filesystem::path& path,
			                  const std::vector<Line>& lines) override
			{
				selectedFullPath_ = path;
				for (const auto& line : lines)
					lines_.push_back(line.lineNumber_);
			}

			const std::filesystem::path selectedFilename_;
			std::filesystem::path selectedFullPath_;
			std::vector<int> lines_;
		};

		//---------------------------------------------------------------------------
		std::vector<int>
		GetLineNumbersWithTag(const std::filesystem::path& path,
		                      const std::wstring& tag)
		{
			std::vector<int> lines;
			std::wifstream ifs(path.wstring());
			std::wstring line;

			for (int lineNumber = 1; std::getline(ifs, line); ++lineNumber)
			{
				if (line.find(tag) != std::wstring::npos)
					lines.push_back(lineNumber);
			}

			return lines;
		}
	}

	//-------------------------------------------------------------------------
	TEST(DebugInformationEnumeratorTest, Enumerate)
	{
		auto selectedPath =
		    TestCoverageConsole::GetDebugInformationEnumeratorTestPath();
		DebugInformationHandlerMock debugInformationHandler{
		    selectedPath.filename()};

		CppCoverage::DebugInformationEnumerator debugInformationEnumerator{ {} };

		auto binary = TestCoverageConsole::GetOutputBinaryPath();
		ASSERT_TRUE(debugInformationEnumerator.Enumerate(
		    binary, debugInformationHandler));

		auto lineWithDebugInfo = GetLineNumbersWithTag(
		    debugInformationHandler.selectedFullPath_, L"@DebugInfoExpected");

		// The MSVC ARM64 compiler emits no line-table entry for a function's
		// closing brace, whereas the x86 and x64 compilers do. This is a
		// documented code-generation difference: OpenCppCoverage faithfully
		// reports the lines present in the PDB, so the closing brace is only
		// expected on architectures whose compiler records it.
#ifndef _M_ARM64
		for (auto closingBraceLine :
		     GetLineNumbersWithTag(debugInformationHandler.selectedFullPath_,
		                           L"@DebugInfoClosingBrace"))
		{
			lineWithDebugInfo.push_back(closingBraceLine);
		}
		std::sort(lineWithDebugInfo.begin(), lineWithDebugInfo.end());
#endif

		ASSERT_FALSE(lineWithDebugInfo.empty());
		ASSERT_EQ(debugInformationHandler.lines_, lineWithDebugInfo);
	}
}