from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy import text
from pydantic_settings import BaseSettings, SettingsConfigDict
import logging

# Configuración de logs para ver qué pasa en la terminal de Docker
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class Settings(BaseSettings):
    """
    Carga las variables de entorno de forma segura.
    Busca automáticamente el archivo .env en la raíz.
    """
    database_url: str
    environment: str = "development"
    
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

settings = Settings()

# Reemplazamos 'postgresql://' por 'postgresql+asyncpg://' para usar el driver asíncrono
async_db_url = settings.database_url.replace("postgresql://", "postgresql+asyncpg://")

# Creamos el motor de base de datos
engine = create_async_engine(
    async_db_url, 
    echo=(settings.environment == "development"), # Muestra las queries SQL en desarrollo
    future=True
)

# Fábrica de sesiones para nuestras rutas
AsyncSessionLocal = async_sessionmaker(
    bind=engine, 
    class_=AsyncSession, 
    expire_on_commit=False
)

# Dependencia para inyectar la sesión de BD en los endpoints
async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()

app = FastAPI(
    title="Mapa Cultural API",
    description="API para gestión y geolocalización de oferta cultural.",
    version="1.0.0"
)

@app.get("/", tags=["Health"])
async def root():
    """
    Endpoint raíz básico para comprobar que la app responde.
    """
    return {
        "status": "online", 
        "project": "Mapa Cultural", 
        "environment": settings.environment
    }

@app.get("/health/db", tags=["Health"])
async def check_db_connection(db: AsyncSession = Depends(get_db)):
    """
    Endpoint para verificar que la conexión a PostGIS funciona correctamente.
    """
    try:
        # Ejecutamos una consulta simple usando el objeto text de SQLAlchemy
        result = await db.execute(text("SELECT 1"))
        value = result.scalar()
        return {"status": "ok", "db_connection": "successful", "value": value}
    except Exception as e:
        logger.error(f"Error conectando a la base de datos: {e}")
        raise HTTPException(status_code=500, detail="Database connection failed")