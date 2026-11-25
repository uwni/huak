cmake_minimum_required(VERSION 3.16)
project(huak_space LANGUAGES CXX)
find_package(OpenCASCADE CONFIG REQUIRED COMPONENTS FoundationClasses ModelingData ModelingAlgorithms)
# An SDK built with precompiled headers exports them to its consumers, which
# hides includes missing from our sources. Compile every source on its own
# includes, whichever SDK is used.
set(CMAKE_DISABLE_PRECOMPILE_HEADERS ON)

# Use the native C++ toolchain and the SDK's imported targets on both sides
# of the OCCT C++ interface. Only the C projection table crosses into Zig.
add_library(space_objects OBJECT model.cpp
  projection.cpp view_curves.cpp view_arrange.cpp view_cells.cpp view_regions.cpp
  arrangement.cpp arrangement_polyline.cpp arrangement_nearest.cpp arrangement_stretches.cpp
  arrangement_crossings.cpp arrangement_arcs.cpp curves.cpp sights.cpp sights_grid.cpp
  contours.cpp contour_boundary.cpp contour_fit.cpp contour_function.cpp contour_grid.cpp
  contour_pieces.cpp)
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
add_executable(space_contour_function_test EXCLUDE_FROM_ALL ../../../tests/space_contour_function.cpp)
target_link_libraries(space_contour_function_test PRIVATE space_objects)
add_executable(space_regions_test EXCLUDE_FROM_ALL ../../../tests/space_regions.cpp)
target_link_libraries(space_regions_test PRIVATE space_objects)
add_executable(space_loader EXCLUDE_FROM_ALL ../../../tests/space_loader.cpp)
target_link_libraries(space_loader PRIVATE ${CMAKE_DL_LIBS})
# Linux RUNPATH only reaches the tests' direct dependencies; the SDK's own
# libraries find each other through the loader path, as OCCT's env.sh sets it.
set(with_sdk ${CMAKE_COMMAND} -E env "LD_LIBRARY_PATH=${OpenCASCADE_LIBRARY_DIR}:$ENV{LD_LIBRARY_PATH}")
add_custom_target(check COMMAND ${with_sdk} $<TARGET_FILE:space_projection_test>
  COMMAND ${with_sdk} $<TARGET_FILE:space_contour_function_test>
  COMMAND ${with_sdk} $<TARGET_FILE:space_regions_test>
  COMMAND ${with_sdk} $<TARGET_FILE:space_loader> $<TARGET_FILE:huak_space>
  DEPENDS space_projection_test space_contour_function_test space_regions_test space_loader huak_space)
