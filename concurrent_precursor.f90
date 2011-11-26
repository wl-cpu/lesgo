!*********************************************************************
module concurrent_precursor
!*********************************************************************
use types, only : rprec
implicit none

save
private

public :: interComm, color, RED, BLUE
public :: vel_sample_t
public :: create_mpi_comms_cps, &
     initialize_cps, &
     synchronize_cps

character (*), parameter :: mod_name = 'concurrent_precursor'

integer, parameter :: RED=0 ! Upstream domain (producer)
integer, parameter :: BLUE=1 ! Downstream domain (consumer) 

integer :: interComm, color

type vel_sample_type
   integer :: nx
   integer :: istart, iend
   integer :: imid
   real(rprec), allocatable, dimension(:,:,:) :: u, v, w
end type vel_sample_type

type(vel_sample_type), target :: vel_sample_t 

contains

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
subroutine create_mpi_comms_cps( localComm )
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
!
! This subroutine does two things. It first splits the MPI_COMM_WORLD
! communicator into two communicators (localComm). The two new
! communicators are then bridged to create an intercommunicator
! (interComm).
! 
use mpi
use param, only : ierr
implicit none

integer, intent(out) :: localComm

integer :: world_np, world_rank
integer :: remoteLeader
integer :: memberKey

! Get number of processors in world comm
call mpi_comm_size (MPI_COMM_WORLD, world_np, ierr)
call mpi_comm_rank (MPI_COMM_WORLD, world_rank, ierr)

! Set color and remote leader for intercommunicator interComm
if( world_rank < world_np / 2 ) then
   color = RED
   remoteLeader = world_np / 2
else
   color = BLUE
   remoteLeader = 0
endif

! Generate member key
memberKey=modulo(world_rank, world_np / 2)

! Split the world communicator into intracommunicators localComm
call MPI_Comm_split(MPI_COMM_WORLD, color, memberKey, localComm, ierr)

! Create intercommunicator interComm
call mpi_intercomm_create( localComm, 0, MPI_COMM_WORLD, remoteLeader, 1, interComm, ierr)

return
end subroutine create_mpi_comms_cps

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
subroutine initialize_cps()
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
use param, only : nx, ny, nz
use param, only : coord, rank_of_coord, status, ierr
use param, only : fringe_region_end, fringe_region_len
use messages
use mpi
implicit none

character (*), parameter :: sub_name = mod_name // '.initialize_cps'

!integer :: rankTest, coordTest

if( color == BLUE ) then

   !--these may be out of 1, ..., nx
   vel_sample_t % iend = floor (fringe_region_end * nx + 1._rprec) - 1
   vel_sample_t % imid = floor (( fringe_region_end - fringe_region_len / 4 ) * nx + 1._rprec)
   vel_sample_t % istart = floor ((fringe_region_end - fringe_region_len) * nx + 1._rprec) + 1

   if( vel_sample_t % iend < 1 .or. vel_sample_t % iend > nx ) call error(sub_name,'iend out of bounds')
   if( vel_sample_t % istart < 1 .or. vel_sample_t % istart > nx ) call error(sub_name,'istart out of bounds')
    
   ! Sample size same as buffer region
   vel_sample_t % nx = vel_sample_t % iend - vel_sample_t % istart + 1
   
   ! Send value to upstream domain (RED)
   call mpi_send( vel_sample_t % nx, 1, MPI_INT, &
        rank_of_coord(coord), 1, interComm, ierr )

elseif( color == RED ) then

   ! Receive from downstream domain (BLUE) 
   call mpi_recv( vel_sample_t % nx , 1, MPI_INT, &
        rank_of_coord(coord), 1, interComm, status, ierr)

   vel_sample_t % iend = nx
   vel_sample_t % istart = vel_sample_t % iend - vel_sample_t % nx + 1

   if( vel_sample_t % iend < 1 .or. vel_sample_t % iend > nx ) call error(sub_name,'iend out of bounds')
   if( vel_sample_t % istart < 1 .or. vel_sample_t % istart > nx ) call error(sub_name,'istart out of bounds')

else

  call error(sub_name,'Erroneous color specification')

endif

allocate( vel_sample_t % u( vel_sample_t % nx, ny, nz) )
allocate( vel_sample_t % v( vel_sample_t % nx, ny, nz) )
allocate( vel_sample_t % w( vel_sample_t % nx, ny, nz) )


return
end subroutine initialize_cps

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
subroutine synchronize_cps()
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
use types, only : rprec
use messages
use param, only : ny, nz
use param, only : coord, rank_of_coord, status, ierr, MPI_RPREC
use sim_param, only : u,v,w
implicit none

character (*), parameter :: sub_name = mod_name // '.synchronize_cps'

real(rprec), pointer, dimension(:,:,:) :: u_p, v_p, w_p
integer, pointer :: nx_p, istart_p, iend_p

integer :: sendsize, recvsize

nullify( u_p, v_p, w_p )
nullify( nx_p, istart_p, iend_p )

istart_p => vel_sample_t % istart
iend_p   => vel_sample_t % iend
nx_p     => vel_sample_t % nx
u_p      => vel_sample_t % u
v_p      => vel_sample_t % v
w_p      => vel_sample_t % w

sendsize = nx_p * ny * nz
recvsize = sendsize

if( color == BLUE ) then

   ! Recieve sampled velocities from upstream (RED)
   call mpi_recv( u_p(1,1,1) , recvsize, MPI_RPREC, &
        rank_of_coord(coord), 1, interComm, status, ierr)
   call mpi_recv( v_p(1,1,1) , recvsize, MPI_RPREC, &
        rank_of_coord(coord), 2, interComm, status, ierr)
   call mpi_recv( w_p(1,1,1) , recvsize, MPI_RPREC, &
        rank_of_coord(coord), 3, interComm, status, ierr)
   
elseif( color == RED ) then

   ! Sample velocity and copy to buffers
   u_p(:,:,:) = u( istart_p:iend_p, 1:ny, 1:nz)
   v_p(:,:,:) = v( istart_p:iend_p, 1:ny, 1:nz)
   w_p(:,:,:) = w( istart_p:iend_p, 1:ny, 1:nz)

   ! Send sampled velocities to downstream domain (BLUE)
   call mpi_send( u_p(1,1,1), sendsize, MPI_RPREC, &
        rank_of_coord(coord), 1, interComm, ierr )
   call mpi_send( v_p(1,1,1), sendsize, MPI_RPREC, &
        rank_of_coord(coord), 2, interComm, ierr )
   call mpi_send( w_p(1,1,1), sendsize, MPI_RPREC, &
        rank_of_coord(coord), 3, interComm, ierr )
   
else

   call error( sub_name, 'Erroneous color specification')
   
endif

nullify( u_p, v_p, w_p )
nullify( nx_p, istart_p, iend_p )

return
end subroutine synchronize_cps

end module concurrent_precursor
