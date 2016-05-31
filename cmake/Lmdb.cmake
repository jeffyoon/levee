include(ExternalProject)

set(LMDB_HASH "LMDB_0.9.18")

set(LMDB_PROJECT "${CMAKE_CURRENT_BINARY_DIR}/lmdb_project_${LMDB_HASH}")
set(LMDB_LIB "${LMDB_PROJECT}/src/lmdb_project/libraries/liblmdb/liblmdb.a")

externalproject_add(lmdb_project
	GIT_REPOSITORY https://github.com/LMDB/lmdb.git
	GIT_TAG ${LMDB_HASH}
	PREFIX ${LMDB_PROJECT}
	CONFIGURE_COMMAND ""
	UPDATE_COMMAND ""
	BUILD_COMMAND cd libraries/liblmdb && make liblmdb.a
	INSTALL_COMMAND ""
	BUILD_IN_SOURCE 1
)
add_library(liblmdb STATIC IMPORTED)
set_target_properties(liblmdb PROPERTIES IMPORTED_LOCATION ${LMDB_LIB})
add_dependencies(liblmdb lmdb_project)
