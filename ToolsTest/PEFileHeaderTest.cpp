// OpenCppCoverage is an open source code coverage for C++.
// Copyright (C) 2026 OpenCppCoverage
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.

#include "stdafx.h"

#include "Tools/PEFileHeader.hpp"
#include "Tools/ToolsException.hpp"

namespace ToolsTest
{
	namespace
	{
		struct HeaderHandler : Tools::IPEFileHeaderHandler
		{
			void OnNtHeader32(HANDLE,
			                  DWORD64,
			                  const IMAGE_NT_HEADERS32&) override
			{
				++header32Count;
			}

			void OnNtHeader64(HANDLE,
			                  DWORD64,
			                  const IMAGE_NT_HEADERS64&) override
			{
				++header64Count;
			}

			int header32Count = 0;
			int header64Count = 0;
		};

		template <typename NtHeader>
		struct TestImage
		{
			TestImage(WORD machine)
			{
				dosHeader.e_magic = IMAGE_DOS_SIGNATURE;
				dosHeader.e_lfanew = offsetof(TestImage, ntHeader);
				ntHeader.Signature = IMAGE_NT_SIGNATURE;
				ntHeader.FileHeader.Machine = machine;
			}

			IMAGE_DOS_HEADER dosHeader{};
			NtHeader ntHeader{};
		};

		template <typename Image>
		HeaderHandler Load(Image& image)
		{
			HeaderHandler handler;
			Tools::PEFileHeader{}.Load(
			    GetCurrentProcess(),
			    reinterpret_cast<DWORD64>(&image),
			    handler);
			return handler;
		}
	}

	TEST(PEFileHeaderTest, LoadsI386Header)
	{
		TestImage<IMAGE_NT_HEADERS32> image{IMAGE_FILE_MACHINE_I386};
		auto handler = Load(image);

		ASSERT_EQ(1, handler.header32Count);
		ASSERT_EQ(0, handler.header64Count);
	}

	TEST(PEFileHeaderTest, LoadsAmd64Header)
	{
		TestImage<IMAGE_NT_HEADERS64> image{IMAGE_FILE_MACHINE_AMD64};
		auto handler = Load(image);

		ASSERT_EQ(0, handler.header32Count);
		ASSERT_EQ(1, handler.header64Count);
	}

	TEST(PEFileHeaderTest, LoadsArm64Header)
	{
		TestImage<IMAGE_NT_HEADERS64> image{IMAGE_FILE_MACHINE_ARM64};
		auto handler = Load(image);

		ASSERT_EQ(0, handler.header32Count);
		ASSERT_EQ(1, handler.header64Count);
	}

	TEST(PEFileHeaderTest, RejectsUnsupportedMachine)
	{
		constexpr WORD Arm64EcMachine = 0xA641;
		TestImage<IMAGE_NT_HEADERS64> image{Arm64EcMachine};
		HeaderHandler handler;

		ASSERT_THROW(
		    Tools::PEFileHeader{}.Load(
		        GetCurrentProcess(),
		        reinterpret_cast<DWORD64>(&image),
		        handler),
		    Tools::ToolsException);
	}
}
