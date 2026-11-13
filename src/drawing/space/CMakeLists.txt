cmake_minimum_required(VERSION 3.16)
project(huak_space LANGUAGES CXX)
find_package(OpenCASCADE CONFIG REQUIRED COMPONENTS FoundationClasses ModelingData ModelingAlgorithms)

# Use the native C++ toolchain and the SDK's imported targets on both sides
# of the OCCT C++ interface. Only the C projection table crosses into Zig.
add_library(space_objects OBJECT model.cpp projection.cpp visibility.cpp lighting.cpp curves.cpp)
target_compile_features(space_objects PUBLIC cxx_std_17)
set_target_properties(space_objects PROPERTIES POSITION_INDEPENDENT_CODE ON
  CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
target_include_directories(space_objects SYSTEM PUBLIC ${OpenCASCADE_INCLUDE_DIR})
target_link_libraries(space_objects PUBLIC TKOffset TKBO TKShHealing TKHLR TKPrim
  TKTopAlgo TKBRep TKGeomAlgo TKGeomBase TKG3d TKG2d TKMath TKernel)

add_library(huak_space SHARED)
target_link_libraries(huak_space PRIVATE space_objects)
if(APPLE)
  set(origin "@loader_path")
else()
  set(origin "$ORIGIN")
endif()
set_target_properties(huak_space PROPERTIES
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/$<CONFIG>"
  BUILD_RPATH "${origin}" INSTALL_RPATH "${origin}")
install(TARGETS huak_space LIBRARY DESTINATION lib)
install(DIRECTORY licenses/ DESTINATION share/licenses/huak/occt)

add_executable(space_projection_test EXCLUDE_FROM_ALL ../../../tests/space_projection.cpp)
target_link_libraries(space_projection_test PRIVATE space_objects)
add_executable(space_loader EXCLUDE_FROM_ALL ../../../tests/space_loader.cpp)
target_link_libraries(space_loader PRIVATE ${CMAKE_DL_LIBS})
# Linux RUNPATH only reaches the tests' direct dependencies; the SDK's own
# libraries find each other through the loader path, as OCCT's env.sh sets it.
set(with_sdk ${CMAKE_COMMAND} -E env "LD_LIBRARY_PATH=${OpenCASCADE_LIBRARY_DIR}:$ENV{LD_LIBRARY_PATH}")
add_custom_target(check COMMAND ${with_sdk} $<TARGET_FILE:space_projection_test>
  COMMAND ${with_sdk} $<TARGET_FILE:space_loader> $<TARGET_FILE:huak_space>
  DEPENDS space_projection_test space_loader huak_space)
