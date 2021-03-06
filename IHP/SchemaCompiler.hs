module IHP.SchemaCompiler
( compile
, compileStatementPreview
) where

import ClassyPrelude
import Data.String.Conversions (cs)
import IHP.NameSupport (tableNameToModelName, columnNameToFieldName)
import Data.Maybe (fromJust)
import qualified Data.Text as Text
import qualified System.Directory as Directory
import Data.List ((!!), (\\))
import Data.List.Split
import IHP.HaskellSupport
import qualified Text.Countable as Countable
import qualified IHP.IDE.SchemaDesigner.Parser as SchemaDesigner
import IHP.IDE.SchemaDesigner.Types
import Control.Monad.Fail

compile :: IO ()
compile = do
    let options = fullCompileOptions
    SchemaDesigner.parseSchemaSql >>= \case
        Left parserError -> fail (cs parserError)
        Right statements -> do
            -- let validationErrors = validate database
            -- unless (null validationErrors) (error $ "Schema.hs contains errors: " <> cs (unsafeHead validationErrors))
            Directory.createDirectoryIfMissing True "build/Generated"
            writeIfDifferent typesFilePath (compileTypes options (Schema statements))

typesFilePath :: FilePath
typesFilePath = "build/Generated/Types.hs"

singularize word = Countable.singularize word

newtype Schema = Schema [Statement]

data CompilerOptions = CompilerOptions {
        -- | We can toggle the generation of @SetField@ and @GetField@ instances.
        -- This is e.g. disabled when showing the code preview in the schema designer
        -- as it's very noisy and does not add any values. But of course it's needed
        -- when do a compilation for the Types.hs
        compileGetAndSetFieldInstances :: Bool
    }

fullCompileOptions :: CompilerOptions
fullCompileOptions = CompilerOptions { compileGetAndSetFieldInstances = True }

previewCompilerOptions :: CompilerOptions
previewCompilerOptions = CompilerOptions { compileGetAndSetFieldInstances = False }

haskellType :: (?schema :: Schema) => Statement -> Column -> Text
haskellType table Column { name, primaryKey } | primaryKey = "(" <> primaryKeyTypeName table <> ")"
haskellType table column@(Column { columnType, notNull }) =
    let
        atomicType = 
            case columnType of
                PInt -> "Int"
                PBigInt -> "Integer"
                PText -> "Text"
                PBoolean   -> "Bool"
                PTimestampWithTimezone -> "UTCTime"
                PUUID -> "UUID"
                PReal -> "Float"
                PDouble -> "Double"
                PDate -> "Data.Time.Calendar.Day"
                PBinary -> "Binary"
                PTime -> "TimeOfDay"
                PCustomType theType -> tableNameToModelName theType
                PTimestamp -> "LocalTime"
                (PNumeric _ _) -> "Float"
                (PVaryingN _) -> "Text"
                (PCharacterN _) -> "Text"
        actualType =
            case findForeignKeyConstraint table column of
                Just (ForeignKeyConstraint { referenceTable }) -> "(" <> primaryKeyTypeName' referenceTable <> ")"
                _ -> atomicType
    in
        if not notNull
            then "(Maybe " <> actualType <> ")"
            else actualType
-- haskellType table (HasMany {name}) = "(QueryBuilder.QueryBuilder " <> tableNameToModelName name <> ")"


writeIfDifferent :: FilePath -> Text -> IO ()
writeIfDifferent path content = do
    alreadyExists <- Directory.doesFileExist path
    existingContent <- if alreadyExists then readFile path else pure ""
    when (existingContent /= cs content) do
        putStrLn $ "Updating " <> cs path
        writeFile (cs path) (cs content)



section = "\n"

compileTypes :: CompilerOptions -> Schema -> Text
compileTypes options schema@(Schema statements) =
        prelude
        <> "\n\n"
        <> let ?schema = schema
            in intercalate "\n\n" (map (compileStatement options) statements)
        <> section
    where
        prelude = "-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.hs` to customize the Types"
                  <> section
                  <> "{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}"
                  <> section
                  <> "module Generated.Types where\n\n"
                  <> "import IHP.HaskellSupport\n"
                  <> "import IHP.ModelSupport\n"
                  <> "import CorePrelude hiding (id) \n"
                  <> "import Data.Time.Clock \n"
                  <> "import qualified Data.Time.Calendar\n"
                  <> "import qualified Data.List as List \n"
                  <> "import qualified Data.ByteString as ByteString \n"
                  <> "import Database.PostgreSQL.Simple\n"
                  <> "import Database.PostgreSQL.Simple.FromRow\n"
                  <> "import Database.PostgreSQL.Simple.FromField hiding (Field, name)\n"
                  <> "import Database.PostgreSQL.Simple.ToField hiding (Field)\n"
                  <> "import qualified IHP.Controller.Param\n"
                  <> "import GHC.TypeLits\n"
                  <> "import Data.UUID (UUID)\n"
                  <> "import Data.Default\n"
                  <> "import qualified IHP.QueryBuilder as QueryBuilder\n"
                  <> "import qualified Data.Proxy\n"
                  <> "import GHC.Records\n"
                  <> "import Data.Data\n"
                  <> "import Database.PostgreSQL.Simple.Types (Query (Query), Binary ( .. ))\n"

compileStatementPreview :: [Statement] -> Statement -> Text
compileStatementPreview statements statement = let ?schema = Schema statements in compileStatement previewCompilerOptions statement

compileStatement :: (?schema :: Schema) => CompilerOptions -> Statement -> Text
compileStatement CompilerOptions { compileGetAndSetFieldInstances } table@(CreateTable {}) =
    compileData table
    <> compileTypeAlias table
    <> compileFromRowInstance table
    <> compileHasTableNameInstance table
    <> compileGetModelName table
    <> compilePrimaryKeyInstance table
    <> compileInclude table
    <> compileCreate table
    <> section
    <> compileUpdate table
    <> section
    <> compileBuild table
    <> section
    <> if compileGetAndSetFieldInstances
            then compileSetFieldInstances table <> compileUpdateFieldInstances table
            else ""
    <> section

compileStatement _ enum@(CreateEnumType {}) = compileEnumDataDefinitions enum
compileStatement _ _ = ""

compileTypeAlias :: (?schema :: Schema) => Statement -> Text
compileTypeAlias table@(CreateTable { name, columns }) =
        "type "
        <> modelName
        <> " = "
        <> modelName
        <> "' "
        <> unwords (map (haskellType table) (variableAttributes table))
        <> hasManyDefaults
        <> "\n"
    where
        modelName = tableNameToModelName name
        hasManyDefaults = columnsReferencingTable name
                |> map (\(tableName, columnName) -> "(QueryBuilder.QueryBuilder " <> tableNameToModelName tableName <> ")")
                |> unwords

primaryKeyTypeName :: Statement -> Text
primaryKeyTypeName CreateTable { name } = primaryKeyTypeName' name

primaryKeyTypeName' :: Text -> Text
primaryKeyTypeName' name = "Id' " <> tshow name <> ""

compileData :: (?schema :: Schema) => Statement -> Text
compileData table@(CreateTable { name, columns }) =
        "data " <> modelName <> "' " <> typeArguments
        <> " = " <> modelName <> " {"
        <> 
            table
            |> dataFields
            |> map (\(fieldName, fieldType) -> fieldName <> " :: " <> fieldType)
            |> commaSep
        <> "} deriving (Eq, Show)\n"
        <> "instance InputValue " <> modelName <> " where inputValue = IHP.ModelSupport.recordToInputValue\n"
    where
        modelName = tableNameToModelName name
        typeArguments :: Text
        typeArguments =  dataTypeArguments table |> unwords

-- | Returns all the type arguments of the data structure for an entity
dataTypeArguments :: (?schema :: Schema) => Statement -> [Text]
dataTypeArguments table = (map columnNameToFieldName belongsToVariables) <> hasManyVariables
    where
        belongsToVariables = variableAttributes table |> map (get #name)
        hasManyVariables = 
            columnsReferencingTable (get #name table)
            |> compileQueryBuilderFields
            |> map snd

-- | Returns the field names and types for the @data MyRecord = MyRecord { .. }@ for a given table
dataFields :: (?schema :: Schema) => Statement -> [(Text, Text)]
dataFields table@(CreateTable { name, columns }) = columnFields <> queryBuilderFields <> [("meta", "MetaBag")]
    where
        columnFields = columns |> map columnField

        columnField column =
            let fieldName = columnNameToFieldName (get #name column)
            in
                ( fieldName
                , if isVariableAttribute table column
                        then fieldName
                        else haskellType table column
                )

        queryBuilderFields = columnsReferencingTable name |> compileQueryBuilderFields

compileQueryBuilderFields :: [(Text, Text)] -> [(Text, Text)]
compileQueryBuilderFields columns = map compileQueryBuilderField columns
    where
        compileQueryBuilderField (refTableName, refColumnName) =
            let
                -- Given a relationship like the following:
                --
                -- CREATE TABLE referrals (
                --     user_id UUID NOT NULL,
                --     referred_user_id UUID DEFAULT uuid_generate_v4() NOT NULL
                -- );
                --
                -- We would have two fields on the @User@ record called @referrals@ which are
                -- going to be used with fetchRelated (user >>= fetchRelated #referrals).
                --
                -- Of course having two fields in the same record does not work, so we have to
                -- detect these duplicate query builder fields and use a more qualified name.
                --
                -- In the example this will lead to two fileds called @referralsUsers@ and @referralsReferredUsers@
                -- being added to the data structure.
                hasDuplicateQueryBuilder =
                    columns
                    |> map fst
                    |> map columnNameToFieldName
                    |> filter (columnNameToFieldName refTableName ==)
                    |> length
                    |> (\count -> count > 1)

                stripIdSuffix :: Text -> Text 
                stripIdSuffix name = fromMaybe name (Text.stripSuffix "_id" name)

                fieldName = if hasDuplicateQueryBuilder
                    then 
                        (refTableName <> "_" <> (refColumnName |> stripIdSuffix))
                        |> columnNameToFieldName
                        |> Countable.pluralize
                    else columnNameToFieldName refTableName
            in
                (fieldName, fieldName)


-- | Finds all the columns referencing a specific table via a foreign key constraint
--
-- __Example:__
--
-- Given the schema:
--
-- > CREATE TABLE users (id SERIAL, company_id INT);
-- > CREATE TABLE companies (id SERIAL);
--
-- you can do the following:
--
-- >>> columnsReferencingTable "companies"
-- [ ("users", "company_id") ]
columnsReferencingTable :: (?schema :: Schema) => Text -> [(Text, Text)]
columnsReferencingTable theTableName = 
    let
        (Schema statements) = ?schema
    in
        statements
        |> mapMaybe \case
            AddConstraint { tableName, constraint = ForeignKeyConstraint { columnName, referenceTable, referenceColumn } } | referenceTable == theTableName -> Just (tableName, columnName)
            _ -> Nothing

variableAttributes :: (?schema :: Schema) => Statement -> [Column]
variableAttributes table@(CreateTable { columns }) = filter (isVariableAttribute table) columns

isVariableAttribute :: (?schema :: Schema) => Statement -> Column -> Bool
isVariableAttribute = isRefCol


-- | Returns @True@ when the coluns is referencing another column via foreign key constraint
isRefCol :: (?schema :: Schema) => Statement -> Column -> Bool
isRefCol table column = isJust (findForeignKeyConstraint table column)

-- | Returns the foreign key constraint bound on the given column
findForeignKeyConstraint :: (?schema :: Schema) => Statement -> Column -> Maybe Constraint
findForeignKeyConstraint CreateTable { name } column =
        case find isFkConstraint statements of
            Just (AddConstraint { constraint }) -> Just constraint
            Nothing -> Nothing
    where
        isFkConstraint (AddConstraint { tableName, constraint = ForeignKeyConstraint { columnName }}) = tableName == name && columnName == get #name column
        isFkConstraint _ = False

        (Schema statements) = ?schema

compileEnumDataDefinitions :: Statement -> Text
compileEnumDataDefinitions enum@(CreateEnumType { name, values }) =
        "data " <> modelName <> " = " <> (intercalate " | " valueConstructors) <> " deriving (Eq, Show, Read, Enum)\n"
        <> "instance FromField " <> modelName <> " where\n"
        <> indent (unlines (map compileFromFieldInstanceForValue values))
        <> "    fromField field (Just value) = returnError ConversionFailed field \"Unexpected value for enum value\"\n"
        <> "    fromField field Nothing = returnError UnexpectedNull field \"Unexpected null for enum value\"\n"
        <> "instance Default " <> modelName <> " where def = " <> tableNameToModelName (unsafeHead values) <> "\n"
        <> "instance ToField " <> modelName <> " where\n" <> indent (unlines (map compileToFieldInstanceForValue values))
        <> "instance InputValue " <> modelName <> " where\n" <> indent (unlines (map compileInputValue values)) <> "\n"
        <> "instance IHP.Controller.Param.ParamReader " <> modelName <> " where readParameter = IHP.Controller.Param.enumParamReader\n"
    where
        modelName = tableNameToModelName name
        valueConstructors = map tableNameToModelName values
        compileFromFieldInstanceForValue value = "fromField field (Just " <> tshow value <> ") = pure " <> tableNameToModelName value
        compileToFieldInstanceForValue value = "toField " <> tableNameToModelName value <> " = toField (" <> tshow value <> " :: Text)"
        compileInputValue value = "inputValue " <> tableNameToModelName value <> " = " <> tshow value <> " :: Text"

compileToRowValues :: [Text] -> Text
compileToRowValues bindingValues | length bindingValues == 1 = "Only (" <> (unsafeHead bindingValues) <> ")"
compileToRowValues bindingValues = "(" <> intercalate ") :. (" (map (\list -> if length list == 1 then "Only (" <> (unsafeHead list) <> ")" else intercalate ", " list) (chunksOf 8 bindingValues)) <> ")"


compileCreate :: Statement -> Text
compileCreate table@(CreateTable { name, columns }) =
    let
        modelName = tableNameToModelName name
        columnNames = commaSep (map (get #name) columns)
        values = commaSep (map (const "?") columns)

        toBinding column@(Column { name }) =
            if hasExplicitOrImplicitDefault column
                then "fieldWithDefault #" <> columnNameToFieldName name <> " model"
                else "get #" <> columnNameToFieldName name <> " model"
            

        bindings :: [Text]
        bindings = map toBinding columns

        createManyFieldValues :: Text
        createManyFieldValues = if null bindings
                then ""
                else "(List.concat $ List.map (\\model -> [" <> (intercalate ", " (map (\b -> "toField (" <> b <> ")") bindings)) <> "]) models)"

        createManyQueryFn :: Text
        createManyQueryFn = "Database.PostgreSQL.Simple." <> if null bindings
                then "query_"
                else "query"
    in
        "instance CanCreate " <> modelName <> " where\n"
        <> indent (
            "create :: (?modelContext :: ModelContext) => " <> modelName <> " -> IO " <> modelName <> "\n"
                <> "create model = do\n"
                <> indent ("let (ModelContext conn) = ?modelContext\n"
                    <> "result <- Database.PostgreSQL.Simple.query conn \"INSERT INTO " <> name <> " (" <> columnNames <> ") VALUES (" <> values <> ") RETURNING *\" (" <> compileToRowValues bindings <> ")\n"
                    <> "pure (List.head result)\n"
                    )
                <> "createMany models = do\n"
                <> indent ("let (ModelContext conn) = ?modelContext\n"
                    <> createManyQueryFn <> " conn (Query $ \"INSERT INTO " <> name <> " (" <> columnNames <> ") VALUES \" <> (ByteString.intercalate \", \" (List.map (\\_ -> \"(" <> values <> ")\") models)) <> \" RETURNING *\") " <> createManyFieldValues <> "\n"
                    )
            )

commaSep :: [Text] -> Text
commaSep = intercalate ", "

toBinding :: Text -> Column -> Text
toBinding modelName Column { name } = "let " <> modelName <> "{" <> columnNameToFieldName name <> "} = model in " <> columnNameToFieldName name

compileUpdate :: Statement -> Text
compileUpdate table@(CreateTable { name, columns }) =
    let
        modelName = tableNameToModelName name

        toUpdateBinding Column { name } = "fieldWithUpdate #" <> columnNameToFieldName name <> " model"

        bindings :: Text
        bindings =
            let
                bindingValues = (map toUpdateBinding columns) <> ["get #id model"]
            in
                compileToRowValues bindingValues

        updates = commaSep (map (\column -> get #name column <> " = ?") columns)
    in
        "instance CanUpdate " <> modelName <> " where\n"
        <> indent ("updateRecord model = do\n"
                <> indent ("let (ModelContext conn) = ?modelContext\n"
                    <> "result <- Database.PostgreSQL.Simple.query conn \"UPDATE " <> name <> " SET " <> updates <> " WHERE id = ? RETURNING *\" (" <> bindings <> ")\n"
                    <> "pure (List.head result)\n"
                )
            )

compileFromRowInstance :: (?schema :: Schema) => Statement -> Text
compileFromRowInstance table@(CreateTable { name, columns }) =
            "instance FromRow " <> modelName <> " where "
            <> ("fromRow = do id <- field; " <> modelName <> " <$> " <>  (intercalate " <*> " $ map compileField (dataFields table))) <> ";\n"
    where
        modelName = tableNameToModelName name
        columnNames = map (columnNameToFieldName . get #name) columns



        referencing = columnsReferencingTable (get #name table)

        isManyToManyField fieldName = fieldName `elem` (referencing |> map (columnNameToFieldName . fst))

        isColumn name = name `elem` columnNames
        compileField ("id", _) = "pure id"
        compileField (fieldName, _) | isColumn fieldName = "field"
        compileField (fieldName, _) | isManyToManyField fieldName = let (Just ref) = find (\(n, _) -> columnNameToFieldName n == fieldName) referencing in compileSetQueryBuilder ref
        compileField _ = "pure def"

        compileSetQueryBuilder (refTableName, refFieldName) = "pure (QueryBuilder.filterWhere (Data.Proxy.Proxy @" <> tshow (columnNameToFieldName refFieldName) <> ", " <> primaryKeyField <> ") (QueryBuilder.query @" <> tableNameToModelName refTableName <> "))"
            where
                -- | When the referenced column is nullable, we have to wrap the @Id@ in @Just@
                primaryKeyField :: Text
                primaryKeyField = if get #notNull refColumn then "id" else "Just id"

                (Just refTable) = let (Schema statements) = ?schema in
                        statements
                        |> find \case
                                CreateTable { name } -> name == refTableName
                                otherwise -> False

                refColumn :: Column
                refColumn = refTable
                        |> \case CreateTable { columns } -> columns
                        |> find (\col -> get #name col == refFieldName)
                        |> \case
                            Just refColumn -> refColumn
                            Nothing -> error (cs $ "Could not find " <> get #name refTable <> "." <> refFieldName <> " referenced by a foreign key constraint. Make sure that there is no typo in the foreign key constraint")


        compileQuery column@(Column { name }) = columnNameToFieldName name <> " = (" <> toBinding modelName column <> ")"
        -- compileQuery column@(Column { name }) | isReferenceColum column = columnNameToFieldName name <> " = (" <> toBinding modelName column <> ")"
        --compileQuery (HasMany hasManyName inverseOf) = columnNameToFieldName hasManyName <> " = (QueryBuilder.filterWhere (Data.Proxy.Proxy @" <> tshow relatedFieldName <> ", " <> (fromJust $ toBinding' (tableNameToModelName name) relatedIdField)  <> ") (QueryBuilder.query @" <> tableNameToModelName hasManyName <>"))"
        --    where
        --        compileInverseOf Nothing = (columnNameToFieldName (singularize name)) <> "Id"
        --        compileInverseOf (Just name) = columnNameToFieldName (singularize name)
        --        relatedFieldName = compileInverseOf inverseOf
        --        relatedIdField = relatedField "id"
        --        relatedForeignKeyField = relatedField relatedFieldName
        --        relatedField :: Text -> Attribute
        --        relatedField relatedFieldName =
        --            let
        --                isFieldName name (Field fieldName _) = (columnNameToFieldName fieldName) == name
        --                (Table _ attributes) = relatedTable
        --            in case find (isFieldName relatedFieldName) (fieldsOnly attributes) of
        --                Just a -> a
        --                Nothing ->
        --                    let (Table tableName _) = relatedTable
        --                    in error (
        --                            "Could not find field "
        --                            <> show relatedFieldName
        --                            <> " in table"
        --                            <> cs tableName
        --                            <> " "
        --                            <> (show $ fieldsOnly attributes)
        --                            <> ".\n\nThis is caused by `+ hasMany " <> show hasManyName <> "`"
        --                        )
        --        relatedTable = case find (\(Table tableName _) -> tableName == hasManyName) database of
        --            Just t -> t
        --            Nothing -> error ("Could not find table " <> show hasManyName)
        --        toBinding' modelName attributes =
        --            case relatedForeignKeyField of
        --                Field _ fieldType | allowNull fieldType -> Just $ "Just (" <> fromJust (toBinding modelName attributes) <> ")"
        --                otherwise -> toBinding modelName attributes

compileBuild :: (?schema :: Schema) => Statement -> Text
compileBuild table@(CreateTable { name, columns }) =
        "instance Record " <> tableNameToModelName name <> " where\n"
        <> "    {-# INLINE newRecord #-}\n"
        <> "    newRecord = " <> tableNameToModelName name <> " " <> unwords (map toDefaultValueExpr columns) <> " " <> (columnsReferencingTable name |> map (const "def") |> unwords) <> " def\n"


toDefaultValueExpr :: Column -> Text
toDefaultValueExpr Column { columnType, notNull, defaultValue = Just theDefaultValue } =
            let
                wrapNull False value = "(Just " <> value <> ")"
                wrapNull True value = value

                isNullExpr (VarExpression varName) = toUpper varName == "NULL"
                isNullExpr _ = False
            in
                if isNullExpr theDefaultValue
                    then "Nothing"
                    else
                        case columnType of
                            PText -> case theDefaultValue of
                                TextExpression value -> wrapNull notNull (tshow value)
                                otherwise            -> error ("toDefaultValueExpr: TEXT column needs to have a TextExpression as default value. Got: " <> show otherwise)
                            PBoolean -> case theDefaultValue of
                                VarExpression value -> wrapNull notNull (tshow (toLower value == "true"))
                                otherwise           -> error ("toDefaultValueExpr: BOOL column needs to have a VarExpression as default value. Got: " <> show otherwise)
                            _ -> "def"
toDefaultValueExpr _ = "def"

compileHasTableNameInstance :: (?schema :: Schema) => Statement -> Text
compileHasTableNameInstance table@(CreateTable { name }) =
    "type instance GetTableName (" <> tableNameToModelName name <> "' " <> unwords (map (const "_") (dataTypeArguments table)) <>  ") = " <> tshow name <> "\n"
    <> "type instance GetModelByTableName " <> tshow name <> " = " <> tableNameToModelName name <> "\n"

compilePrimaryKeyInstance :: (?schema :: Schema) => Statement -> Text
compilePrimaryKeyInstance table@(CreateTable { name, columns }) = "type instance PrimaryKey " <> tshow name <> " = " <> idType <> "\n"
    where
        idColumn :: Column
        (Just idColumn) = find (get #primaryKey) columns

        idType :: Text
        idType = case get #columnType idColumn of
                PUUID -> "UUID"
                PSerial -> "Int"
                PBigserial -> "Integer"
                otherwise -> error ("Unexpected type for primary key column in table" <> cs name)

compileGetModelName :: (?schema :: Schema) => Statement -> Text
compileGetModelName table@(CreateTable { name }) = "type instance GetModelName (" <> tableNameToModelName name <> "' " <> unwords (map (const "_") (dataTypeArguments table)) <>  ") = " <> tshow (tableNameToModelName name) <> "\n"

compileDataTypePattern :: (?schema :: Schema) => Statement -> Text
compileDataTypePattern table@(CreateTable { name }) = tableNameToModelName name <> " " <> unwords (table |> dataFields |> map fst)

compileTypePattern :: (?schema :: Schema) => Statement -> Text
compileTypePattern table@(CreateTable { name }) = tableNameToModelName name <> "' " <> unwords (dataTypeArguments table)

compileInclude :: (?schema :: Schema) => Statement -> Text
compileInclude table@(CreateTable { name, columns }) = (belongsToIncludes <> hasManyIncludes) |> unlines
    where
        belongsToIncludes = map compileBelongsTo (filter (isRefCol table) columns)
        hasManyIncludes = columnsReferencingTable name |> map compileHasMany 
        typeArgs = dataTypeArguments table
        modelName = tableNameToModelName name
        modelConstructor = modelName <> "'"

        includeType :: Text -> Text -> Text
        includeType fieldName includedType = "type instance Include " <> tshow fieldName <> " (" <> leftModelType <> ") = " <> rightModelType <> "\n"
            where
                leftModelType = unwords (modelConstructor:typeArgs)
                rightModelType = unwords (modelConstructor:(map compileTypeVariable' typeArgs))
                compileTypeVariable' name | name == fieldName = includedType
                compileTypeVariable' name = name

        compileBelongsTo :: Column -> Text
        compileBelongsTo column = includeType (columnNameToFieldName (get #name column)) ("(GetModelById " <> columnNameToFieldName (get #name column) <> ")")

        compileHasMany :: (Text, Text) -> Text
        compileHasMany (refTableName, refColumnName) = includeType (columnNameToFieldName refTableName) ("[" <> tableNameToModelName refTableName <> "]")


compileSetFieldInstances :: (?schema :: Schema) => Statement -> Text
compileSetFieldInstances table@(CreateTable { name, columns }) = unlines (map compileSetField (dataFields table))
    where
        setMetaField = "instance SetField \"meta\" (" <> compileTypePattern table <>  ") MetaBag where\n    {-# INLINE setField #-}\n    setField newValue (" <> compileDataTypePattern table <> ") = " <> tableNameToModelName name <> " " <> (unwords (map (get #name) columns)) <> " newValue"
        modelName = tableNameToModelName name
        typeArgs = dataTypeArguments table
        compileSetField (name, fieldType) =
            "instance SetField " <> tshow name <> " (" <> compileTypePattern table <>  ") " <> fieldType <> " where\n" <>
            "    {-# INLINE setField #-}\n" <>
            "    setField newValue (" <> compileDataTypePattern table <> ") =\n" <>
            "        " <> modelName <> " " <> (unwords (map compileAttribute (table |> dataFields |> map fst)))
            where
                compileAttribute name'
                    | name' == name = "newValue"
                    | name' == "meta" = "(meta { touchedFields = \"" <> name <> "\" : touchedFields meta })"
                    | otherwise = name'

compileUpdateFieldInstances :: (?schema :: Schema) => Statement -> Text
compileUpdateFieldInstances table@(CreateTable { name, columns }) = unlines (map compileSetField (dataFields table))
    where
        modelName = tableNameToModelName name
        typeArgs = dataTypeArguments table
        compileSetField (name, fieldType) = "instance UpdateField " <> tshow name <> " (" <> compileTypePattern table <>  ") (" <> compileTypePattern' name  <> ") " <> valueTypeA <> " " <> valueTypeB <> " where\n    {-# INLINE updateField #-}\n    updateField newValue (" <> compileDataTypePattern table <> ") = " <> modelName <> " " <> (unwords (map compileAttribute (table |> dataFields |> map fst)))
            where
                (valueTypeA, valueTypeB) =
                    if name `elem` typeArgs
                        then (name, name <> "'")
                        else (fieldType, fieldType)

                compileAttribute name'
                    | name' == name = "newValue"
                    | name' == "meta" = "(meta { touchedFields = \"" <> name <> "\" : touchedFields meta })"
                    | otherwise = name'

                compileTypePattern' ::  Text -> Text
                compileTypePattern' name = tableNameToModelName (get #name table) <> "' " <> unwords (map (\f -> if f == name then name <> "'" else f) (dataTypeArguments table))

-- | Indents a block of code with 4 spaces.
--
-- Empty lines are not indented.
indent :: Text -> Text
indent code = code
        |> Text.lines
        |> map indentLine
        |> Text.unlines
    where
        indentLine ""   = ""
        indentLine line = "    " <> line

-- | Returns 'True' when the column has an explicit default value or when it's a SERIAL or BIGSERIAL
hasExplicitOrImplicitDefault :: Column -> Bool
hasExplicitOrImplicitDefault column = case column of
        Column { defaultValue = Just _ } -> True
        Column { columnType = PSerial } -> True
        Column { columnType = PBigserial } -> True
        _ -> False