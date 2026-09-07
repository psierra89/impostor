import { z } from 'zod'

export const nicknameSchema = z
  .string()
  .trim()
  .min(2, 'El apodo necesita al menos 2 caracteres')
  .max(20, 'Máximo 20 caracteres')

export const roomCodeSchema = z
  .string()
  .trim()
  .toUpperCase()
  .regex(/^[A-Z0-9]{6}$/, 'El código debe tener 6 letras o números')

export const proposalSchema = z
  .string()
  .trim()
  .min(2, 'Mínimo 2 caracteres')
  .max(60, 'Máximo 60 caracteres')
